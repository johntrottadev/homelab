# docker-2 Periphery v2 — install runbook

Komodo Periphery v2.2.0 native systemd binary on docker-2 (__LAN-IP__), outbound to docker-3 Komodo Core (http://__LAN-IP__:9120) via Ed25519 PKI.

Authored by Phase 11 plan 11-02 (2026-05-14). The legacy `komodo` compose stack on docker-2 (a v1 Periphery container in `/opt/komodo/periphery-only.yaml`) coexists with this v2 systemd Periphery during the migration window; the v1 container becomes inert once docker-1's v1 Core is decommissioned in plan 11-01c.

## Periphery binary version pin

Single-binary fleet across docker-1, docker-2, app-vm — see [`docker-1/periphery/README.md`](../../docker-1/periphery/README.md) for the canonical version-pin table. As of 2026-05-14 the same v2.2.0 binary (SHA256 `ace9007805dbfe75ad73c75c36bb26852fa909d825577f31f5d13eecd3c52660`) is deployed on docker-2.

## On-host paths

Same as docker-1's layout:

| Path | Purpose |
|------|---------|
| `/usr/local/bin/periphery` | Binary (mode 0755, root:root) |
| `/etc/komodo/periphery.config.toml` | Config (mode 0600, root:root, no `onboarding_key` after rotation) |
| `/etc/komodo/keys/periphery.key` + `.pub` | Long-lived Ed25519 keypair |
| `/etc/komodo/keys/core.pub` | docker-3 Core's pubkey captured at onboarding |
| `/etc/systemd/system/periphery.service` | systemd unit |

## Stacks managed by this Periphery

| Komodo Stack name | project_name | compose path |
|-------------------|--------------|--------------|
| `lacus` | `lacus` | `docker-2/lacus/compose.yaml` (uses `build:` — set `run_build: true` on the Stack so Komodo rebuilds; auto_pull would fail) |

(The `legacy-vm-docker-2` and `komodo` compose projects also running on docker-2 are legacy v1 Komodo deployments — they get cleaned up in plan 11-01c, NOT registered on docker-3.)

## See also

- [`docker-1/periphery/README.md`](../../docker-1/periphery/README.md) — canonical install procedure (use the same script with `connect_as = "docker-2"` and the docker-2 onboarding key).
- [`docker-3/README.md`](../../docker-3/README.md) — Core host that this Periphery talks to.
- [`docker-2/README.md`](../README.md) — host-level docker-2 runbook.
