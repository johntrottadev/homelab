#!/usr/bin/env python3
# Wazuh active-response: register srcip with PA's wazuh-blocked tag so the
# wazuh-auto-block DAG (and the wazuh-auto-block-deny security rule) match it.
#
# Wazuh AR contract: stdin is a JSON alert with shape:
#   {"version": 1, "origin": {...}, "command": "add"|"delete", "parameters": {...}}
#
# Source IP lives in parameters.alert.data.srcip for most rules.
#
# Credentials are read from /var/ossec/etc/pa-block.conf (KEY=value lines):
#   PA_HOST=__LAN-IP__
#   PA_API_KEY=...
#
# TLS: the PA mgmt cert is verified BEFORE the API key is sent (fail closed).
# Optional conf/env keys (see pa_tls_connection below):
#   PA_TLS_MODE=pin|ca        default pin (the PA's self-signed cert has no SAN
#                             and KeyUsage=certSign only, so chain checks fail)
#   PA_CA_FILE=<pem>          default: pa-ca.pem next to this script
#   PA_CERT_SHA256=<hex>      optional explicit leaf pin; else derived from PA_CA_FILE
#
# Whitelist: any srcip inside 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16,
# 127.0.0.0/8, 169.254.0.0/16 is skipped (only public-internet sources can be blocked).
import json
import sys
import ipaddress
import urllib.parse
import os
import ssl
import hmac
import hashlib
import http.client
import syslog

CONF_PATH = "/var/ossec/etc/pa-block.conf"
DEFAULT_CA_FILE = os.path.join(os.path.dirname(os.path.realpath(__file__)), "pa-ca.pem")
TAG = "wazuh-blocked"
TIMEOUT_SECONDS = 3600

WHITELIST_NETS = [
    ipaddress.ip_network("10.0.0.0/8"),
    ipaddress.ip_network("172.16.0.0/12"),
    ipaddress.ip_network("192.168.0.0/16"),
    ipaddress.ip_network("127.0.0.0/8"),
    ipaddress.ip_network("169.254.0.0/16"),
    ipaddress.ip_network("100.64.0.0/10"),
]


def log(msg, level=syslog.LOG_INFO):
    syslog.openlog("pa-block", syslog.LOG_PID, syslog.LOG_AUTH)
    syslog.syslog(level, msg)


def load_conf():
    cfg = {}
    if not os.path.isfile(CONF_PATH):
        log(f"missing config {CONF_PATH}", syslog.LOG_ERR)
        sys.exit(1)
    with open(CONF_PATH) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if "=" not in line:
                continue
            k, v = line.split("=", 1)
            cfg[k.strip()] = v.strip()
    for required in ("PA_HOST", "PA_API_KEY"):
        if required not in cfg:
            log(f"config missing {required}", syslog.LOG_ERR)
            sys.exit(1)
    return cfg


def is_whitelisted(ip):
    try:
        addr = ipaddress.ip_address(ip)
    except ValueError:
        return True  # not a valid IP, refuse to block
    return any(addr in net for net in WHITELIST_NETS)


class PaTLSError(Exception):
    """PA mgmt TLS identity could not be verified; nothing was sent."""


def pa_tls_connection(host, timeout, ca_file, pin_sha256="", mode="pin"):
    """Return an HTTPSConnection whose TLS handshake is already done AND verified.

    Raises PaTLSError before any request (and so before the API key) is sent.
      mode "ca":  normal chain + hostname verification against ca_file.
      mode "pin": the handshake cannot use chain verification (the PA's self-signed
                  mgmt cert fails OpenSSL's purpose check), so the peer leaf DER is
                  compared to a pinned SHA-256: pin_sha256, else sha256 of ca_file.
    """
    if mode == "ca":
        try:
            ctx = ssl.create_default_context(cafile=ca_file)
        except (OSError, ssl.SSLError) as e:
            raise PaTLSError(f"cannot load PA CA file {ca_file}: {e}")
    elif mode == "pin":
        pin = (pin_sha256 or "").replace(":", "").strip().lower()
        if not pin:
            try:
                with open(ca_file) as f:
                    pin = hashlib.sha256(ssl.PEM_cert_to_DER_cert(f.read())).hexdigest()
            except (OSError, ValueError) as e:
                raise PaTLSError(f"cannot load pinned PA cert {ca_file}: {e}")
        if len(pin) != 64 or any(c not in "0123456789abcdef" for c in pin):
            raise PaTLSError("PA_CERT_SHA256 is not a 64-hex SHA-256 fingerprint")
        ctx = ssl.create_default_context()
        ctx.check_hostname = False  # tls-guard: pinned (leaf fingerprint checked below)
        ctx.verify_mode = ssl.CERT_NONE  # tls-guard: pinned (leaf fingerprint checked below)
    else:
        raise PaTLSError(f"unknown PA_TLS_MODE {mode!r} (expected pin or ca)")
    conn = http.client.HTTPSConnection(host, timeout=timeout, context=ctx)
    try:
        conn.connect()
    except ssl.SSLError as e:
        conn.close()
        raise PaTLSError(f"TLS handshake with PA failed verification: {e}")
    if mode == "pin":
        der = conn.sock.getpeercert(binary_form=True) or b""
        got = hashlib.sha256(der).hexdigest()
        if not hmac.compare_digest(got, pin):
            conn.close()
            raise PaTLSError(f"PA cert fingerprint mismatch (got sha256 {got}); refusing to send API key")
    return conn


def _tls_opt(cfg, name, default=""):
    return cfg.get(name) or os.environ.get(name) or default


def pa_api_get(cfg, params, timeout=10):
    """GET /api/?<params> over a verified connection. Returns (status, body)."""
    conn = pa_tls_connection(
        cfg["PA_HOST"], timeout,
        ca_file=_tls_opt(cfg, "PA_CA_FILE", DEFAULT_CA_FILE),
        pin_sha256=_tls_opt(cfg, "PA_CERT_SHA256"),
        mode=_tls_opt(cfg, "PA_TLS_MODE", "pin").lower(),
    )
    try:
        conn.request("GET", "/api/?" + urllib.parse.urlencode(params))
        resp = conn.getresponse()
        return resp.status, resp.read().decode("utf-8", errors="replace")
    finally:
        conn.close()


def register_block(cfg, srcip, action):
    op = "register" if action == "add" else "unregister"
    inner = (
        f"<entry ip=\"{srcip}\" persistent=\"0\">"
        f"<tag><member timeout=\"{TIMEOUT_SECONDS}\">{TAG}</member></tag>"
        f"</entry>"
    )
    cmd_xml = f"<uid-message><type>update</type><payload><{op}>{inner}</{op}></payload></uid-message>"
    params = {
        "type": "user-id",
        "action": "set",
        "cmd": cmd_xml,
        "key": cfg["PA_API_KEY"],
    }
    try:
        status, body = pa_api_get(cfg, params)
    except PaTLSError as e:
        log(f"pa user-id {op} ip={srcip} tls_error={e}", syslog.LOG_ERR)
        sys.exit(4)
    except Exception as e:
        log(f"pa user-id {op} transport_error={e}", syslog.LOG_ERR)
        sys.exit(3)
    if status >= 400:
        log(f"pa user-id {op} ip={srcip} http_error={status} body={body[:200]}", syslog.LOG_ERR)
        sys.exit(2)
    log(f"pa user-id {op} ip={srcip} http={status} body={body[:200]}")

def main():
    raw = sys.stdin.read()
    if not raw.strip():
        log("empty stdin, exiting", syslog.LOG_WARNING)
        sys.exit(0)
    try:
        msg = json.loads(raw)
    except Exception as e:
        log(f"unparseable stdin: {e}", syslog.LOG_ERR)
        sys.exit(1)

    command = msg.get("command", "add")  # add | delete
    alert = (msg.get("parameters") or {}).get("alert") or {}
    data = alert.get("data") or {}
    srcip = data.get("srcip") or data.get("src_ip") or data.get("source_ip")
    if not srcip:
        log(f"no srcip in alert (rule {(alert.get('rule') or {}).get('id', '?')})")
        sys.exit(0)

    if is_whitelisted(srcip):
        log(f"whitelisted srcip {srcip}, skipping ({command})")
        sys.exit(0)

    cfg = load_conf()
    register_block(cfg, srcip, command)


if __name__ == "__main__":
    main()
