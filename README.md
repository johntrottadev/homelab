# flux-source — homelab GitOps target state

Flux watches this repo and applies `clusters/default/`. Per-app subdirs
under `clusters/default/<app>/` hold the full workload (Namespace, PV,
PVC, Deployment, Service, IngressRoute) for apps that have been migrated
to flux. Other apps live as single-file IngressRoute stubs at the repo
root.

See `INFRASTRUCTURE.md` for the homelab inventory and the per-app
table.

## Flux-managed app workloads

| App                  | Hostname                | Subdir                          |
|----------------------|-------------------------|---------------------------------|
| uptime-kuma          | uptime.__BASE-DOMAIN__       | `clusters/default/uptime-kuma/` |
| netalert (NetAlertX) | netalert.__BASE-DOMAIN__     | `clusters/default/netalert/`    |
| loki                 | (internal-only)         | `clusters/default/loki/`        |
| promtail             | (DaemonSet)             | `clusters/default/loki/`        |

### Helm-shipped apps

Apps that ship via Helm (e.g., Loki) live under their own per-app subdir
and reference a shared `HelmRepository` in `flux-system` (see the `grafana`
HelmRepository in `clusters/default/loki/helmrepository-grafana.yaml`).
Future Grafana-stack apps reuse the same HelmRepository instead of
declaring their own.

`loki` has **no IngressRoute** and **no LoadBalancer Service** — it is
internal-only. Grafana (in the `monitoring` ns) queries Loki via the
in-cluster ClusterIP at `loki.loki.svc.cluster.local:3100`. Do not add an
IngressRoute for Loki without explicitly re-evaluating the security posture
(logs may contain secrets in error stacks).

## Repository conventions

- Image references are pinned to digests, never `:latest`.
- PVs are statically bound (`volumeName`) for deterministic PVC binds.
- IngressRoutes use the websecure entrypoint and the wildcard cert
  `*.__BASE-DOMAIN__` issued by cert-manager (Phase 14).
- flux-system uses `prune: false` — manifest deletions in this repo do
  NOT auto-delete cluster objects. Run `kubectl delete` explicitly when
  retiring an app (see bastion quick task 260429-npe for an example).

## Related repos

- `~/projects/bastion` — planning artifacts, monitoring scripts,
  operational tooling. The `.planning/` tree there is the journal of
  cluster work.
