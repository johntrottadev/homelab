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
# Whitelist: any srcip inside 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16,
# 127.0.0.0/8, 169.254.0.0/16 is skipped (only public-internet sources can be blocked).
import json
import sys
import ipaddress
import urllib.request
import urllib.parse
import urllib.error
import os
import syslog

CONF_PATH = "/var/ossec/etc/pa-block.conf"
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


def register_block(cfg, srcip, action):
    op = "register" if action == "add" else "unregister"
    inner = (
        f"<entry ip=\"{srcip}\" persistent=\"0\">"
        f"<tag><member timeout=\"{TIMEOUT_SECONDS}\">{TAG}</member></tag>"
        f"</entry>"
    )
    cmd_xml = f"<uid-message><type>update</type><payload><{op}>{inner}</{op}></payload></uid-message>"
    params = urllib.parse.urlencode({
        "type": "user-id",
        "action": "set",
        "cmd": cmd_xml,
        "key": cfg["PA_API_KEY"],
    })
    url = f"https://{cfg['PA_HOST']}/api/?{params}"
    import ssl
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    req = urllib.request.Request(url, method="GET")
    try:
        with urllib.request.urlopen(req, timeout=10, context=ctx) as resp:
            body = resp.read().decode("utf-8", errors="replace")
            log(f"pa user-id {op} ip={srcip} http={resp.status} body={body[:200]}")
    except urllib.error.HTTPError as e:
        log(f"pa user-id {op} ip={srcip} http_error={e.code} body={e.read().decode('utf-8', errors='replace')[:200]}", syslog.LOG_ERR)
        sys.exit(2)
    except Exception as e:
        log(f"pa user-id {op} transport_error={e}", syslog.LOG_ERR)
        sys.exit(3)


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
