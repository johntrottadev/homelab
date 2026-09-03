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

## Containment is not built yet

`pa-block.py` blocks EXTERNAL attackers and structurally cannot contain an
internal host: it whitelists all of RFC1918 and needs an `srcip`, which host-based
alerts (FIM, rootcheck, process) never carry. Internal containment needs a sibling
`pa-quarantine.py`. Design and safety rails:
`~/AI-Backbone/standards/security/wazuh-response-design.md`.
