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
