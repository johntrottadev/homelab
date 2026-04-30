#!/usr/bin/env python3
"""PALOARP — pull ARP + DHCP leases from a Palo Alto firewall via the PAN-OS
XML API and feed them into NetAlertX. Modeled on the upstream `arp_scan`
plugin's use of Plugin_Objects."""

import os
import ssl
import sys
import urllib.parse
import urllib.request
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
VERIFY_TLS = (_env("PALO_VERIFY_TLS") or _setting("PALOARP_VERIFY_TLS") or "true").lower() == "true"
IFACE_INCLUDE = _split_csv(_env("PALO_IFACE_INCLUDE") or _setting("PALOARP_IFACE_INCLUDE"))
IFACE_EXCLUDE = _split_csv(_env("PALO_IFACE_EXCLUDE") or _setting("PALOARP_IFACE_EXCLUDE"))
TIMEOUT = int(_env("PALO_TIMEOUT") or _setting("PALOARP_TIMEOUT") or "20")


def pa_op(cmd_xml: str) -> ET.Element:
    url = (
        f"https://{PA_HOST}/api/?type=op"
        f"&cmd={urllib.parse.quote(cmd_xml)}"
        f"&key={urllib.parse.quote(PA_KEY)}"
    )
    ctx = ssl.create_default_context()
    if not VERIFY_TLS:
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
    with urllib.request.urlopen(url, context=ctx, timeout=TIMEOUT) as r:
        body = r.read()
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
