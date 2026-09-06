# Homelab Alert Runbooks

One section per alert defined in `monitoring/homelab-alerts.yaml`. Linked
from each alert's `runbook_url` annotation, so this file's anchored sections
appear in Pushover notifications and the Grafana alert list.

Anchor format is `#<alertname-lowercase>` — keep section headings exactly
matching the alert name.

---

## VeleroDailyBackupStale

**What it means**: The Velero `daily-apps` schedule hasn't produced a
successful backup in over 30 hours.

**What to check**
- `kubectl get backups -n velero --sort-by=.metadata.creationTimestamp | tail -5` — confirm absence
- `kubectl get podvolumebackups -n velero` — look for stuck/Failed PVBs
- Velero pod logs: `kubectl logs -n velero -l app.kubernetes.io/name=velero --tail=200`
- Wasabi S3 reachability + auth: `kubectl get bsl -n velero` (BackupStorageLocation status)

**How to fix**
- Failed BSL → re-apply the BSL Secret with refreshed Wasabi keys
- Schedule paused → `velero schedule unpause daily-apps`
- Stuck PVB → `velero backup delete <name> --confirm` then re-trigger

## VeleroWeeklyBackupStale

Same procedure as `VeleroDailyBackupStale` but for `weekly-apps` schedule.
Threshold is 8 days. Less urgent — daily covers most app data.

## VeleroBackupRecentFailure

**What it means**: A Velero backup in the last 24h ended with `Failed` or
`PartiallyFailed` phase.

**What to check**
- Identify the backup CR: `kubectl get backups -n velero | grep -i 'fail'`
- `velero describe backup <name> --details` — pulls the per-resource error
  list, item failures, PVB errors
- Common cause: a single namespace/PVC failed (e.g. CSI snapshot timeout)

**How to fix**
- Per-PVB failure → check Kopia uploader logs in the PVB pod
- Re-run: `velero backup create <name>-retry --from-schedule daily-apps`
- If the same item fails repeatedly, exclude it via `--exclude-namespaces`
  or annotate the PVC with `backup.velero.io/backup-volumes-excludes`

## VeleroBackupStorageDown

**What it means**: A Velero `BackupStorageLocation` is `Unavailable`.
New backups cannot upload until restored.

**What to check**
- `kubectl get bsl -n velero -o wide`
- `kubectl describe bsl <name> -n velero` — last validation error
- Wasabi S3 console — bucket exists, credentials valid

**How to fix**
- Refresh the cloud creds Secret, then `kubectl rollout restart deploy velero -n velero`
- Network path: confirm DNS + egress from k3s to Wasabi endpoint

---

## PVENodeDown

**What it means**: pve-exporter reports a Proxmox node as down for 5+ min.

**What to check**
- Ping the raw IP (__PVE1-IP__/11/12) — exporter scrapes via cluster API
- PVE Web UI for the cluster status (any node may serve)
- IPMI/iLO out-of-band if local console is needed

**How to fix**
- If hardware is up but node fenced: `pvecm updatecerts -f` from another node
- If quorum lost: `pvecm expected 1` (single-node mode) to recover
- Power cycle as last resort

## PVEGuestUnexpectedlyDown

**What it means**: A guest with `onboot=1` is not running for 10+ min.

**What to check**
- PVE web UI → Tasks tab → look for failed start tasks
- Guest config: `qm config <vmid>` or `pct config <ctid>`

**How to fix**
- Manual start: `qm start <vmid>` / `pct start <ctid>`
- If start fails, examine error in tasks log — often a storage-not-ready,
  PCI passthrough device missing, or kernel mismatch on LXC

## PVEStorageHigh / PVEStorageCritical

**What it means**: PVE storage is >85% (warning) / >92% (critical) full.

**What to check**
- Storage view in PVE UI shows what's consuming space
- Old backups (`/var/lib/vz/dump/*` for local storage)
- Stale ISO uploads, decommissioned guest disks

**How to fix**
- Prune old backups in PBS retention
- Remove unreferenced disks: `pvesm scan` and look for orphans
- Free large items first; storage doesn't need to be drastically pruned

---

## PBSExporterDown

**What it means**: backup-host-exporter pod can't be scraped or can't reach PBS.

**What to check**
- `kubectl get pod -n monitoring -l app.kubernetes.io/name=backup-host-exporter`
- backup-host-exporter logs (look for 403 = token perms, 401 = auth, network = host unreachable)
- PBS host alive at https://__LAN-IP__:8007

**How to fix**
- 403 → API token missing perms; add `Audit` role at `/` to the token
- 401 → token rotated; refresh `backup-host-exporter-credentials` Secret
- Pod CrashLoop → restart and re-check env var → flag mapping

## PBSDatastoreHigh / PBSDatastoreCritical

**What it means**: PBS datastore is >85% / >92% full.

**What to check**
- PBS UI → Datastore → Summary
- Snapshot retention: are very old historical backups still kept?
- Garbage collection schedule: should run weekly

**How to fix**
- Run prune now: PBS UI → Datastore → Prune (preview first)
- Run GC: PBS UI → Datastore → GC Schedule (or manually)
- Adjust retention policy if too generous

## PBSVMBackupStale

**What it means**: A VM has a backup in PBS but its most recent successful
backup is >36h old (filtered to VMs with backups in the last 14 days, so
decommissioned VMs don't keep alerting).

**What to check**
- PVE backup job config — is the VMID still in the job's vmid selector?
- PVE Tasks tab — look for failed backup tasks for that VMID
- Storage availability when the backup ran (NFS mount, PBS reachable)

**How to fix**
- Add VMID back to the backup schedule in `Datacenter → Backup`
- Re-run the backup job manually
- If the VM was renamed but VMID reused, the alert reflects the previous
  VM; either prune old snapshots or disable the alert via silence

## PBSVerifyStale

**What it means**: no snapshot of this VM has passed verification on this
datastore in **over 30 days**. Backups are being taken; nobody has proven
they can be read back.

**This replaced `PBSBackupVerifyFailed` and `PBSArchiveVerifyFailed` on
2026-09-06.** Those alerted on `pbs_snapshot_vm_last_verify == 0`, which
cannot tell *"verify failed"* from *"not verified yet"*. Backups land every
2h and the verify job runs once daily at 05:00, so the newest snapshot is
unverified for most of every day. Measured across 2 days, the old rule was
firing 45-48% of wall-clock against **healthy** data - 19 alerts at once on
the morning it was removed. It was the largest single source of alert noise
in the estate, and it trained the reflex of ignoring PBS alerts, which is
the actual damage.

**Why the rule looks unusual**: it reads a recording rule,
`backup-host:last_verify_ok:timestamp`, rather than `max_over_time(...[30d])`.
Prometheus holds roughly **2 days** of history here - `spec.retention` is
10d but `retentionSize=34GB` binds first at ~442k head series. A `[30d]`
range would silently evaluate over ~2 days and look like it worked. The
recording rule carries the last-known-good verify time forward one sample at
a time, so it needs no history at all.

**What to check**
- PBS UI -> Datastore -> Verify Jobs - does a verify schedule exist and is
  it enabled?
- If it exists, check its last run in the PBS task log.
- 30 days is deliberately generous. If this fires, something has been broken
  for a month - check the schedule before the data.

**How to fix**
- No verify job -> create one in the PBS UI. Weekly is sufficient.
- Verify failed -> read the PBS task log. Usually a corrupt chunk; either
  `proxmox-backup-manager verify --resume` or restore from the parallel
  snapshot on the other datastore.
- Alert will clear on its own within one evaluation of a successful verify.

**Known limitation - a Prometheus restart forgives staleness.** The carry-
forward chain reads its own previous sample. When Prometheus restarts, that
sample is gone, so every VM re-seeds to "verified now" and the 30-day clock
restarts from zero. A genuinely stale image is silently forgiven and needs
another full 30 days to alert again. This is inherent: the PBS exporter
publishes `pbs_snapshot_vm_last_verify` as a **boolean only** - there is no
verify-timestamp metric to read the true value from (confirmed against the
full `pbs_*` metric list, 2026-09-06). Mitigations: `PBSVMBackupStale` is
unaffected and still catches a VM that stopped being backed up at all, and
after a known Prometheus restart, check the PBS UI verify-job history
directly rather than trusting this alert for the following month.

**Scope note**: the alert excludes `datastore="2tb"`, the archive replica
whose disk failed and is being wiped. `PBSVMBackupStale` carries the same
exclusion. **Remove both together** once the archive is rebuilt.

---

## SynologySNMPDown

**What it means**: snmp-exporter cannot reach Synology NAS at __NAS-IP__.

**What to check**
- DSM Control Panel → Terminal & SNMP → SNMP service still enabled?
- DSM Allowed IPs list still includes __LAN-SVC-CIDR__?
- SNMPv3 user still exists with same auth/priv passwords?

**How to fix**
- Restart SNMP service in DSM
- Verify creds match `snmp-exporter-credentials` Secret keys

## SynologyDiskUnhealthy

**What it means**: A disk reports `diskHealthStatus > 1` (anything beyond
"Normal" — Initialized/NotInitialized/SystemPartitionFailed/Crashed).

**What to check**
- DSM Storage Manager → HDD/SSD tab — overall and per-disk status
- SMART data: DSM → Storage Manager → click disk → Health

**How to fix**
- `Crashed` → replace disk; volume may need RAID rebuild
- `SystemPartitionFailed` → DSM repair via Storage Manager → Online Assemble
- Lower-severity statuses → check SMART, plan replacement if degrading

## SynologyDiskRemainLifeLow

**What it means**: SSD wear-leveling indicator < 20% (lifetime remaining).
HDDs report -1 and are excluded by the alert expression.

**What to check**
- Confirm in DSM Storage Manager → SSD details → Lifespan
- Cross-check with manufacturer SMART: `Wear_Leveling_Count` attribute

**How to fix**
- Plan SSD replacement before <10% remaining
- For RAID-protected SSDs you can hot-swap with parity rebuild

---

## PaloAltoSNMPDown

**What it means**: snmp-exporter cannot reach Palo Alto at __LAN-IP__ via
either the `paloalto_fw` or `if_mib` job. Conditional: only fires if
device was previously seen up in the last 24h.

**What to check**
- Direct snmpwalk from k3s-1: `snmpwalk -v3 -l authPriv -u admin -a SHA -A ... -x AES -X ... __LAN-IP__ 1.3.6.1.2.1.1`
- PAN-OS UI → Device → Setup → Operations → SNMP Setup — enabled + committed?
- Device → Setup → Interfaces → Management → Services — SNMP checkbox + permitted IPs

**How to fix**
- Most common: PAN-OS commit was rolled back. Re-commit.
- Mgmt iface IP changed → update the Probe target

## PaloAltoSessionUtilizationHigh / Critical

**What it means**: Active sessions > 50% / 80% of `panSessionMax` (131,070).
Homelab usually sits at <1%, so a real spike means a scan, attack, or
runaway client.

**What to check**
- Top sources by sessions in PAN-OS UI: Monitor → Session Browser
- Pi-hole top clients (DNS-driven session creation)
- Recent firewall log spikes: Monitor → Logs → Traffic

**How to fix**
- Identify offending client by source IP, isolate or rate-limit at firewall
- If legit, raise capacity / consider PA-820 → bigger box

## PaloAltoSessionDiscardsSpike

**What it means**: `rate(panSessionDiscard[5m]) > 5/s` for 15min. Sessions
are being denied or session-table-evicted.

**What to check**
- Monitor → Logs → Traffic, filter by Action=deny
- Threats log if WildFire/IPS is active

**How to fix**
- Policy issue → adjust security rule
- Session pressure → see SessionUtilization runbook

## PaloAltoInterfaceSaturationHigh / Critical

**What it means**: A physical interface is sustained >80% / >95% of link
speed for 10m / 5m (peak direction, in or out).

**What to check**
- Which interface — is it WAN (ISP issue) or LAN (internal heavy lifter)?
- PAN-OS Monitor → Interface → Realtime to see flow distribution

**How to fix**
- WAN: probably saturating ISP link — QoS / cap heavy users
- LAN: bursty backup or replication — schedule off-peak

## PaloAltoInterfaceErrorsSpike

**What it means**: Interface input errors > 1/s. Usually layer-1 (cable,
SFP, duplex mismatch).

**What to check**
- Interface counters in PAN-OS UI
- Cable continuity, replace SFP module
- Duplex auto-negotiation results

**How to fix**
- Re-seat cable / replace
- Force link speed on both ends if auto-neg is unstable

---

## PiholeExporterDown

**What it means**: pihole-exporter pod can't be scraped or can't reach
either Pi-hole instance.

**What to check**
- `kubectl get pod -n monitoring -l app.kubernetes.io/name=pihole-exporter`
- Container logs — looking for auth failures (`/api/auth → 401`)

**How to fix**
- 401 → app password rotated; refresh `pihole-exporter-credentials` Secret
- Pod CrashLoop → describe pod, check probe failures

## PiholeDisabled

**What it means**: One Pi-hole instance has `pihole_status=0` for 15min —
ad-blocking has been manually disabled in the admin UI.

**What to check**
- Pi-hole admin UI → Top of page shows blocking enabled / disabled toggle
- Long Term Data → Settings — if "Permanently disable" was selected

**How to fix**
- Re-enable from the admin UI (or via API)
- If left off intentionally, silence the alert in Alertmanager

## PiholeUpstreamSlow

**What it means**: Average upstream DNS response time > 0.5s for 15min.
Excludes cache and blocklist (those are local).

**What to check**
- NextDNS status: status.nextdns.io
- Local network latency to upstream IP
- Pi-hole admin UI → Tools → Top permitted/blocked, Network Tab → Active queries

**How to fix**
- If upstream is the issue, change resolvers temporarily (Cloudflare 1.1.1.1)
- If local network, diagnose with ping/traceroute from pihole VM

---

## WANDown

**What it means**: Both public TCP/53 probes (1.1.1.1 and 8.8.8.8) failing
simultaneously for 2+ min. Either Cloudflare AND Google are down (extremely
unlikely) OR our WAN is broken.

**What to check**
- ISP modem indicator lights
- Palo Alto WAN interface state — Monitor → Interface
- LAN-side: ping anything outside (`ping 1.1.1.1` from any host)

**How to fix**
- ISP outage → wait / call
- Palo Alto WAN interface down → check cable, restart interface
- Routing change → review recent firewall commits

## PublicDNSResolutionFailing

**What it means**: A public DNS resolver (1.1.1.1 or 8.8.8.8) isn't
responding to DNS queries from k3s. Less severe than WANDown — could be
just one upstream having issues.

**What to check**
- Try the other public resolver to confirm it's resolver-specific
- Network path from k3s → public resolver

**How to fix**
- Wait it out if the resolver vendor is having issues
- If persistent, switch primary resolver in Pi-hole upstreams

---

## HomelabPVCHigh / HomelabPVCCritical

**What it means**: A Persistent Volume Claim is >85% / >92% full.

**What to check**
- `kubectl get pvc -A` to confirm the PVC + namespace
- App that owns the PVC — is it accumulating logs/data unbounded?
- Storage Health dashboard's PVC bargauge for trend

**How to fix**
- Resize PVC: edit the PVC's `spec.resources.requests.storage` (must be
  supported by the storage class — most NFS PVs in this cluster are static
  and need a manual resize)
- Or prune the data inside the volume from the pod
