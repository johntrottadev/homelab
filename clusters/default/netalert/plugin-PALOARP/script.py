#!/usr/bin/env python3
"""PALOARP — pull ARP + DHCP leases from a Palo Alto firewall via the PAN-OS
XML API and feed them into NetAlertX. Modeled on the upstream `arp_scan`
plugin's use of Plugin_Objects."""

import hashlib
import hmac
import http.client
import os
import ssl
import sys
import urllib.parse
import xml.etree.ElementTree as ET

# Wire up NetAlertX's Python helpers (same shape as arp_scan/script.py).
INSTALL_PATH = os.getenv("NETALERTX_APP", "/app")
sys.path.extend([f"{INSTALL_PATH}/front/plugins", f"{INSTALL_PATH}/server"])

from plugin_helper import Plugin_Objects, handleEmpty  # noqa: E402
from logger import mylog, Logger                        # noqa: E402
from helper import get_setting_value                    # noqa: E402
from const import logPath                               # noqa: E402
import conf                                              # noqa: E402
from pytz import timezone                                # noqa: E402

conf.tz = timezone(get_setting_value("TIMEZONE"))
Logger(get_setting_value("LOG_LEVEL"))

pluginName = "PALOARP"
RESULT_FILE = os.path.join(logPath, "plugins", f"last_result.{pluginName}.log")


def _setting(name: str, default: str = "") -> str:
    """Read a NetAlertX setting; tolerate missing keys."""
    try:
        v = get_setting_value(name)
        return "" if v is None else str(v)
    except Exception:
        return default


def _env(name: str, default: str = "") -> str:
    return os.environ.get(name, default)


def _split_csv(value: str) -> set[str]:
    return {x.strip() for x in value.split(",") if x.strip()}


# Secrets via env (k8s Secret); non-secrets via NetAlertX settings.
PA_HOST = _env("PALO_HOST") or _setting("PALOARP_HOST")
PA_KEY = _env("PALO_API_KEY") or _setting("PALOARP_API_KEY")
# PA mgmt TLS is always verified before the key is sent (no opt-out; the old
# PALO_VERIFY_TLS / PALOARP_VERIFY_TLS switch is ignored). Default: pin the public
# cert mounted from the `pa-mgmt-cert` ConfigMap.
PA_TLS_MODE = _env("PA_TLS_MODE", "pin").lower()
PA_CA_FILE = _env("PA_CA_FILE", "/etc/pa-tls/pa-mgmt.pem")
PA_CERT_SHA256 = _env("PA_CERT_SHA256")
IFACE_INCLUDE = _split_csv(_env("PALO_IFACE_INCLUDE") or _setting("PALOARP_IFACE_INCLUDE"))
IFACE_EXCLUDE = _split_csv(_env("PALO_IFACE_EXCLUDE") or _setting("PALOARP_IFACE_EXCLUDE"))
TIMEOUT = int(_env("PALO_TIMEOUT") or _setting("PALOARP_TIMEOUT") or "20")


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



def pa_op(cmd_xml: str) -> ET.Element:
    path = f"/api/?type=op&cmd={urllib.parse.quote(cmd_xml)}&key={urllib.parse.quote(PA_KEY)}"
    conn = pa_tls_connection(PA_HOST, TIMEOUT, PA_CA_FILE, PA_CERT_SHA256, PA_TLS_MODE)
    try:
        conn.request("GET", path)
        body = conn.getresponse().read()
    finally:
        conn.close()
    root = ET.fromstring(body)
    if root.attrib.get("status") != "success":
        raise RuntimeError(f"PA API error: {ET.tostring(root, encoding='unicode')[:400]}")
    return root


def fetch_arp() -> list[dict]:
    """List of dicts {mac, ip, interface} from `show arp all`."""
    root = pa_op("<show><arp><entry name='all'/></arp></show>")
    out: list[dict] = []
    for entry in root.findall(".//entries/entry"):
        mac = (entry.findtext("mac") or "").strip().lower()
        ip = (entry.findtext("ip") or "").strip()
        iface = (entry.findtext("interface") or "").strip()
        status = (entry.findtext("status") or "").strip().lower()

        if not mac or not ip or mac in ("(incomplete)", "00:00:00:00:00:00"):
            continue
        if "i" in status:  # 'i' = incomplete
            continue
        if IFACE_INCLUDE and iface not in IFACE_INCLUDE:
            continue
        if iface in IFACE_EXCLUDE:
            continue

        out.append({"mac": mac, "ip": ip, "interface": iface})
    return out


def fetch_dhcp_hostnames() -> dict[str, str]:
    """Best-effort MAC -> hostname; returns {} on any failure."""
    try:
        root = pa_op(
            "<show><dhcp><server><lease><interface>all</interface></lease></server></dhcp></show>"
        )
    except Exception as exc:
        mylog("warning", [f"[{pluginName}] DHCP lease fetch failed: {exc}"])
        return {}

    leases: dict[str, str] = {}
    for entry in root.iter("entry"):
        mac = (entry.findtext("mac") or "").strip().lower()
        host = (entry.findtext("hostname") or "").strip()
        if mac and host:
            leases[mac] = host
    return leases


def main() -> int:
    mylog("verbose", [f"[{pluginName}] starting"])

    if not PA_HOST or not PA_KEY:
        mylog("none", [f"[{pluginName}] PALO_HOST and PALO_API_KEY (or PALOARP_HOST/PALOARP_API_KEY settings) are required"])
        return 2

    plugin_objects = Plugin_Objects(RESULT_FILE)
    hostnames = fetch_dhcp_hostnames()
    arp = fetch_arp()

    seen: set[str] = set()
    for d in arp:
        mac = d["mac"]
        if mac in seen:
            continue
        seen.add(mac)
        plugin_objects.add_object(
            primaryId=handleEmpty(mac),
            secondaryId=handleEmpty(d["ip"]),
            watched1=handleEmpty(d["ip"]),                # IP (devLastIP)
            watched2="",                                   # vendor — let NetAlertX OUI lookup populate
            watched3=handleEmpty(d["interface"]),         # PA interface / VLAN
            watched4=handleEmpty(hostnames.get(mac, "")), # DHCP hostname (informational)
            extra=pluginName,
            foreignKey="",
        )

    plugin_objects.write_result_file()
    mylog("verbose", [f"[{pluginName}] emitted {len(seen)} devices ({len(hostnames)} dhcp hostnames)"])
    return 0


if __name__ == "__main__":
    sys.exit(main())
