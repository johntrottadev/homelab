# Monitoring stack

`kube-prometheus-stack` Helm release named `prometheus` in the `monitoring`
namespace. Deploys Prometheus, Alertmanager, Grafana, kube-state-metrics,
node-exporter, and prometheus-operator.

## Files

| File | Purpose |
|---|---|
| `values.yaml` | Helm values — scrape config, alert routing, kps tunings |
| `alertmanager-pv.yaml` / `grafana-pv.yaml` / `prometheus-pv.yaml` | Static NFS PVs |
| `ingress.yaml` | `grafana.__BASE-DOMAIN__` and `prometheus.__BASE-DOMAIN__` |
| `grafana-dashboard-velero-per-app.yaml` | Custom Velero per-app dashboard |
| `pushover-secret.yaml.example` | Template for the Alertmanager Pushover Secret |
| `homelab-alerts.yaml` | Custom PrometheusRule (velero, pve, network, k8s, backup-host, synology, paloalto) |
| `blackbox-exporter.yaml` | blackbox-exporter Deployment + Service + Probe CRs |
| `backup-host-exporter.yaml` | natrontech/backup-host-exporter Deployment + Service + ServiceMonitor |
| `snmp-exporter.yaml` | snmp-exporter Deployment (with envsubst init) + Probe CRs (Synology, PAN-OS) |
| `snmp.yml` | snmp-exporter config (vendored from snmp_exporter v0.27.0 release; modules: synology, paloalto_fw, if_mib) |
| `grafana-dashboard-paloalto.yaml` | Palo Alto firewall dashboard ConfigMap (13 panels: capacity, sessions, interfaces, discards) |

## Custom alert coverage

Beyond the kube-prometheus-stack defaults, `homelab-alerts.yaml` adds:

| Group | Alerts |
|---|---|
| `homelab.velero.rules` | `VeleroDailyBackupStale` (>30h), `VeleroWeeklyBackupStale` (>8d), `VeleroBackupRecentFailure` (24h window), `VeleroBackupStorageDown` |
| `homelab.pve.rules` | `PVENodeDown`, `PVEGuestUnexpectedlyDown` (onboot=1 only), `PVEStorageHigh` (>85%), `PVEStorageCritical` (>92%) |
| `homelab.network.rules` | `WANDown` (both public TCP/53 probes failing), `PublicDNSResolutionFailing` |
| `homelab.k8s.rules` | `HomelabPVCHigh` (>85%), `HomelabPVCCritical` (>92%) |
| `homelab.backup-host.rules` | `PBSExporterDown`, `PBSDatastoreHigh` (>85%), `PBSDatastoreCritical` (>92%), `PBSVMBackupStale` (>36h, scoped to last 14d), `PBSBackupVerifyFailed` |
| `homelab.synology.rules` | `SynologySNMPDown`, `SynologyDiskUnhealthy`, `SynologyDiskRemainLifeLow` (<20% wear life) |
| `homelab.paloalto.rules` | `PaloAltoSNMPDown` (only fires after device has been seen up — avoids false-fires during initial config) |

Probes (via blackbox-exporter):

- `wan` — TCP/53 to 1.1.1.1 and 8.8.8.8
- `public_dns` — DNS A query for `cloudflare.com` against 1.1.1.1 and 8.8.8.8

Probes (via snmp-exporter):

- `synology` — __NAS-IP__, SNMPv3 with `synology` module
- `paloalto` — __LAN-IP__, SNMPv3 with `paloalto_fw` module

## Wave 2B credential bootstrap

PBS API token + SNMPv3 creds live in `/Volumes/code/secrets/homelab/monitoring/wave-2b-secrets.yaml` (off-repo, NFS-shared with k3s-1 as `/mnt/code/secrets`). They get rendered into k8s Secrets via `kubectl create secret ... --dry-run=client -o yaml | kubectl apply -f -`.

Per-exporter Secret keys:

| Secret | Keys (from wave-2b-secrets.yaml) |
|---|---|
| `backup-host-exporter-credentials` | `username` (`<user>@<realm>` from `backup-host.api_token_id`), `token-name` (`<tokenname>`), `token-secret` (`backup-host.api_token_secret`) |
| `snmp-exporter-credentials` | `synology-username`, `synology-auth-pass`, `synology-priv-pass`, `paloalto-username`, `paloalto-auth-pass`, `paloalto-priv-pass` |

The `snmp-exporter` uses an init container with `envsubst` to render `/etc/snmp_exporter/snmp.yml` from `snmp.yml.tmpl` + the env vars at pod start.

## Apply workflow (run from k3s-1)

The cluster kubeconfig at `/etc/rancher/k3s/k3s.yaml` is root-only.

```bash
# One-time: create Pushover Secret from real values (do not commit)
kubectl create secret generic pushover-creds -n monitoring \
  --from-literal=user_key='YOUR_USER_KEY' \
  --from-literal=token='YOUR_APP_TOKEN' \
  --dry-run=client -o yaml | sudo kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml apply -f -

# Helm upgrade (chart pinned to the version Helm history is on)
sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml helm upgrade prometheus \
  prometheus-community/kube-prometheus-stack \
  --version 69.3.1 \
  -n monitoring \
  -f /mnt/code/homelab/monitoring/values.yaml
```

For flat manifest changes (alert rules, blackbox-exporter), `kubectl apply`:

```bash
sudo kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml apply \
  -f /mnt/code/homelab/monitoring/homelab-alerts.yaml \
  -f /mnt/code/homelab/monitoring/blackbox-exporter.yaml
```

## Alert routing

Alertmanager routes by `severity` label:

| severity | Pushover priority | Repeat interval |
|---|---|---|
| `critical` | `1` (high) | 1 h |
| `warning` | `0` (normal) | 4 h |
| `info` | dropped (`null` receiver) | n/a |

`Watchdog` and `InfoInhibitor` alerts are also dropped. Bump `priority` to `2`
in `values.yaml` for emergency (ack-required) on specific receivers if/when a
class of alert warrants it.

## Known constraints

- k3s control-plane components (controller-manager / scheduler / proxy / etcd)
  bind metrics to `127.0.0.1` by default. Their kps scrape jobs are disabled.
  Re-enable by passing `--kube-*-arg=bind-address=0.0.0.0` (and
  `--etcd-expose-metrics=true`) to k3s servers, then flip `enabled: true` in
  `values.yaml`.
- All NFS-backed PVs are static. Helm does not manage them.
- Pi-hole exporter is **not deployed** on pihole1 — scrape removed from
  `additionalScrapeConfigs`. Re-add when the exporter is installed.
