#!/usr/bin/env python3
# Wazuh active-response: QUARANTINE an internal endpoint by registering the
# AGENT'S OWN IP with the Palo Alto `wazuh-quarantine` tag, matched by a DAG that
# is referenced as BOTH source and destination in a deny rule -- i.e. a network
# black hole, not a one-way block.
#
# This is the deliberate mirror of pa-block.py. Every difference matters:
#
#                     pa-block.py                 pa-quarantine.py
#   IP source         alert.data.srcip            alert.agent.ip  (the host itself)
#   RFC1918           whitelisted (skipped)       REQUIRED (public refused)
#   Tag               wazuh-blocked               wazuh-quarantine
#   Expiry            3600s, self-clearing        PERSISTENT, human release only
#   DAG match         source only                 source AND destination
#   Triggers on       alerts carrying srcip       FIM / rootcheck / process alerts
#
# pa-block.py cannot do containment: it whitelists exactly the address space an
# internal endpoint lives in, and requires an srcip that host-based alerts never
# carry.
#
# Credentials: /var/ossec/etc/pa-block.conf (shared with pa-block.py)
#   PA_HOST=...
#   PA_API_KEY=...
#
# Manual use:
#   pa-quarantine.py --status            list what is currently quarantined
#   pa-quarantine.py --release <ip>      lift a quarantine
#   pa-quarantine.py --dry-run <ip>      show what WOULD happen, change nothing
#
# Wazuh AR use: invoked with the alert JSON on stdin.

import json
import sys
import ipaddress
import urllib.request
import urllib.parse
import urllib.error
import os
import ssl
import syslog

CONF_PATH = "/var/ossec/etc/pa-block.conf"
TAG = "wazuh-quarantine"

# Quarantine is for INTERNAL endpoints only. A public IP reaching this script
# means the alert was misrouted -- pa-block.py handles external addresses.
INTERNAL_NETS = [
    ipaddress.ip_network("10.0.0.0/8"),
    ipaddress.ip_network("172.16.0.0/12"),
    ipaddress.ip_network("192.168.0.0/16"),
]

# ---------------------------------------------------------------------------
# NEVER-QUARANTINE LIST
#
# This list is the entire safety story of this script. Isolating any host below
# causes an outage worse than the compromise it is responding to, and in several
# cases severs the path needed to LIFT the quarantine.
#
# Adding an entry is cheap. Removing one is a decision that should be argued for
# in writing.
# ---------------------------------------------------------------------------
NEVER_QUARANTINE = {
    # DNS. Isolating a resolver breaks name resolution estate-wide, including
    # for every other remediation step.
    "__PIHOLE1-IP__": "pihole1 - DNS",
    "__PIHOLE2-IP__": "pihole2 - DNS",

    # Subnet routers. These carry the tailnet path used to reach the estate
    # remotely -- including the path used to run the release command.
    "__LAN-IP__": "netbird-exit-1 - subnet router",
    "__LAN-IP__": "netbird-exit-2 - subnet router / tailnet SNAT exit",
    "__LAN-IP__": "netbird-exit-3 - subnet router",

    # Hypervisors. Isolating one isolates every guest running on it, and severs
    # the console path used to recover them.
    "__LAN-IP__": "__PVE-NODE-1__ - hypervisor",
    "__LAN-IP__": "__PVE-NODE-2__ - hypervisor",
    "__LAN-IP__": "__PVE-NODE-3__ - hypervisor",
    "__PVE1-IP__": "__PVE-NODE-1__ - hypervisor (cluster net)",
    "__PVE2-IP__": "__PVE-NODE-2__ - hypervisor (cluster net)",
    "__PVE3-IP__": "__PVE-NODE-3__ - hypervisor (cluster net)",

    # Backup server. Needed to restore whatever was just quarantined.
    "__LAN-IP__": "backup-host - backup server",

    # Bastion and cluster VIPs.
    "__LAN-IP__": "bastion bastion",
    "__LAN-IP__": "k3s control-plane API VIP",
    "__LAN-IP__": "traefik LB VIP",

    # The Wazuh host itself. Quarantining the manager blinds the sensor and
    # prevents the release command from being issued.
    "__LAN-IP__": "docker-1 - wazuh manager",
}


def log(msg, level=syslog.LOG_INFO):
    syslog.openlog("pa-quarantine", syslog.LOG_PID, syslog.LOG_AUTH)
    syslog.syslog(level, msg)


def load_conf():
    cfg = {}
    if not os.path.isfile(CONF_PATH):
        log(f"missing config {CONF_PATH}", syslog.LOG_ERR)
        sys.exit(1)
    with open(CONF_PATH) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            cfg[k.strip()] = v.strip()
    for required in ("PA_HOST", "PA_API_KEY"):
        if required not in cfg:
            log(f"config missing {required}", syslog.LOG_ERR)
            sys.exit(1)
    return cfg


def refusal_reason(ip):
    """Return a string reason to REFUSE, or None if the IP may be quarantined.

    Fails safe: anything unparseable or unexpected is refused, never allowed.
    """
    if not ip:
        return "no IP supplied"
    if ip in NEVER_QUARANTINE:
        return f"protected infrastructure ({NEVER_QUARANTINE[ip]})"
    try:
        addr = ipaddress.ip_address(ip)
    except ValueError:
        return f"not a valid IP address: {ip!r}"
    if not any(addr in net for net in INTERNAL_NETS):
        return f"{ip} is not RFC1918 - quarantine is for internal endpoints only"
    return None


def pa_userid(cfg, ip, op):
    """op is 'register' or 'unregister'. persistent=1, no timeout: a quarantine
    must outlive a PA reboot and must not silently lapse."""
    inner = f'<entry ip="{ip}" persistent="1"><tag><member>{TAG}</member></tag></entry>'
    cmd_xml = f"<uid-message><type>update</type><payload><{op}>{inner}</{op}></payload></uid-message>"
    params = urllib.parse.urlencode({
        "type": "user-id",
        "action": "set",
        "cmd": cmd_xml,
        "key": cfg["PA_API_KEY"],
    })
    url = f"https://{cfg['PA_HOST']}/api/?{params}"
    # Matches pa-block.py. The PA presents a self-signed certificate on the
    # management interface; see the note in the README about pinning it.
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    req = urllib.request.Request(url, method="GET")
    try:
        with urllib.request.urlopen(req, timeout=10, context=ctx) as resp:
            body = resp.read().decode("utf-8", errors="replace")
            log(f"pa user-id {op} ip={ip} tag={TAG} http={resp.status} body={body[:200]}")
            return body
    except urllib.error.HTTPError as e:
        log(f"pa user-id {op} ip={ip} http_error={e.code} "
            f"body={e.read().decode('utf-8', errors='replace')[:200]}", syslog.LOG_ERR)
        sys.exit(2)
    except Exception as e:
        log(f"pa user-id {op} transport_error={e}", syslog.LOG_ERR)
        sys.exit(3)


def show_status(cfg):
    params = urllib.parse.urlencode({
        "type": "op",
        "cmd": f"<show><object><registered-ip><tag><entry name='{TAG}'/></tag></registered-ip></object></show>",
        "key": cfg["PA_API_KEY"],
    })
    url = f"https://{cfg['PA_HOST']}/api/?{params}"
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    try:
        with urllib.request.urlopen(urllib.request.Request(url), timeout=10, context=ctx) as resp:
            print(resp.read().decode("utf-8", errors="replace"))
    except Exception as e:
        print(f"status query failed: {e}", file=sys.stderr)
        sys.exit(3)


def main():
    # ---- manual modes -----------------------------------------------------
    if len(sys.argv) > 1:
        arg = sys.argv[1]
        if arg == "--status":
            show_status(load_conf())
            return
        if arg in ("--release", "--dry-run"):
            if len(sys.argv) < 3:
                print(f"usage: {sys.argv[0]} {arg} <ip>", file=sys.stderr)
                sys.exit(64)
            ip = sys.argv[2]
            if arg == "--dry-run":
                why = refusal_reason(ip)
                print(f"{ip}: {'REFUSED - ' + why if why else 'would be quarantined'}")
                return
            # Release deliberately skips refusal_reason: lifting a quarantine is
            # always safe, and must work even for an address that could never
            # have been quarantined in the first place.
            pa_userid(load_conf(), ip, "unregister")
            print(f"{ip}: quarantine released")
            log(f"manual release ip={ip}", syslog.LOG_WARNING)
            return
        print(f"unknown option {arg!r}", file=sys.stderr)
        sys.exit(64)

    # ---- Wazuh active-response mode ---------------------------------------
    raw = sys.stdin.read()
    if not raw.strip():
        log("empty stdin, exiting", syslog.LOG_WARNING)
        sys.exit(0)
    try:
        msg = json.loads(raw)
    except Exception as e:
        log(f"unparseable stdin: {e}", syslog.LOG_ERR)
        sys.exit(1)

    command = msg.get("command", "add")
    alert = (msg.get("parameters") or {}).get("alert") or {}
    agent = alert.get("agent") or {}
    rule = alert.get("rule") or {}

    # The agent's own address -- NOT srcip. This is the host being contained.
    ip = agent.get("ip")
    agent_name = agent.get("name", "?")

    if not ip:
        log(f"no agent.ip in alert (rule {rule.get('id','?')}, agent {agent_name}) - "
            f"cannot quarantine an agent whose address is unknown", syslog.LOG_WARNING)
        sys.exit(0)

    if command == "delete":
        pa_userid(load_conf(), ip, "unregister")
        log(f"released ip={ip} agent={agent_name}", syslog.LOG_WARNING)
        return

    why = refusal_reason(ip)
    if why:
        log(f"REFUSED quarantine of {ip} (agent {agent_name}, rule {rule.get('id','?')}): {why}",
            syslog.LOG_WARNING)
        sys.exit(0)

    log(f"QUARANTINING ip={ip} agent={agent_name} rule={rule.get('id','?')} "
        f"level={rule.get('level','?')} desc={str(rule.get('description',''))[:120]}",
        syslog.LOG_WARNING)
    pa_userid(load_conf(), ip, "register")


if __name__ == "__main__":
    main()
