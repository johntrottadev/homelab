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
