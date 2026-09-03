# Wazuh — docker-1

## Why these files are here

Until 2026-09-02 the detection rules and active-response scripts existed **only**
inside Docker named volumes (`wazuh_etc`, `wazuh_active_response`) on docker-1. They
were backed up by kopia, but not diffable, reviewable or revertible — a rule change
that caused an outage could not be compared against a known-good version.

They are now version-controlled here and pushed into the running container by
`sync-rules.sh`.

## Layout

    rules/                     -> /var/ossec/etc/rules/          (detection + tuning)
      local_rules.xml            custom detections
      lab_noise_rules.xml        noise suppression for this estate
      k3s_audit_rules.xml        k3s audit-log rules
      sanitize_heartbeat_rules.xml
    active-response/           -> /var/ossec/active-response/bin/
      pa-block.py                tags an EXTERNAL srcip `wazuh-blocked` on the PA
                                 via User-ID API; 3600s auto-expiry

## What is deliberately NOT here

- `/var/ossec/etc/ossec.conf` — carries local tuning; sync it deliberately, not
  as a side effect of a rules push.
- `/var/ossec/etc/pa-block.conf` — PA_HOST and PA_API_KEY. Credentials stay on
  the host (root:root 0600). Never commit this file.

## Deploying

    ./sync-rules.sh          # copies rules + AR scripts in, restarts the manager

The manager is restarted, not the whole stack — the indexer and dashboard are
unaffected and agents reconnect on their own.

## Containment: pa-quarantine.py (present, NOT YET ARMED)

`pa-block.py` blocks EXTERNAL attackers and structurally cannot contain an
internal host: it whitelists all of RFC1918 and needs an `srcip`, which host-based
alerts (FIM, rootcheck, process) never carry.

`pa-quarantine.py` is its mirror: it takes the AGENT'S OWN ip, REQUIRES RFC1918,
tags `wazuh-quarantine` persistently, and refuses a hard-coded list of
infrastructure that must never be isolated (DNS, subnet routers, hypervisors,
PBS, the bastion, cluster VIPs, and the Wazuh host itself).

**It is currently inert.** Three things are required before it can fire, in order:

1. **On the Palo Alto:** create a Dynamic Address Group matching tag
   `wazuh-quarantine`, and a deny rule referencing that DAG as BOTH source and
   destination. Source-only is a half-block, not containment.
2. **Test the release path FIRST**, before any trigger exists:
       ./pa-quarantine.py --dry-run __LAN-IP__    # shows verdict, changes nothing
       ./pa-quarantine.py --status                 # what is quarantined now
       ./pa-quarantine.py --release <ip>           # lift it
   A quarantine you cannot lift quickly is an outage.
3. **Only then** add an `<active-response>` block to ossec.conf pointing at it,
   scoped to ONE narrow high-confidence rule. Widen later, never at the start.

Design, tiers and rationale:
`~/AI-Backbone/standards/security/wazuh-response-design.md`

### Known wart, shared with pa-block.py
Both scripts set `ssl.CERT_NONE` against the PA management interface. That is
tolerable on a management VLAN but means neither script would notice an
interception. Pinning the PA certificate is worth doing to both at once.
