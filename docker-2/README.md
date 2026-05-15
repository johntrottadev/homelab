# docker-2 — secondary docker compose host

docker-2 (__LAN-IP__, ProxMox VM) hosts a thin set of standalone compose stacks that don't fit the k3s cluster (typically because they need host-level networking, libpcap, raw bind mounts, or just colocation with a specific service). It does NOT run Komodo Core — that lives on docker-3 (__LAN-IP__) per Phase 11 plan 11-01a.

## Layout

```
docker-2/
├── README.md              # this file
├── .env.example           # per-host env schema (gitignored *.env applies)
├── lacus/                 # Lacus capture system (URL-fetch via Playwright/Chromium)
│   └── compose.yaml
└── periphery/             # Komodo Periphery v2 systemd binary docs
    ├── README.md
    ├── periphery.config.toml
    └── periphery.service
```

## Running compose projects (as of 2026-05-14)

| project_name | source | role | managed by |
|--------------|--------|------|------------|
| `lacus` | `docker-2/lacus/compose.yaml` | URL-fetch capture system; AIL on app-vm calls docker-2:7100 | docker-3 Core (Komodo Stack `lacus`) |
| `komodo` | `/opt/komodo/periphery-only.yaml` | LEGACY v1 Periphery container — will be decommissioned in plan 11-01c | (none — direct compose) |
| `legacy-vm-docker-2` | `/etc/komodo/stacks/legacy-vm-docker-2/docker-1/legacy-vm/compose.yaml` | LEGACY v1-Komodo-deployed copy of legacy-vm — will be reconciled in plan 11-01c | (legacy v1 Komodo on docker-1) |

## NAS path convention

Compose stacks that need persistent state mount under `/mnt/kub/homelab/<svc>/` (CIFS to NAS at __NAS-IP__). docker-2's lacus stack uses Docker named volumes for its Valkey state; no NAS mount required for lacus. Future stacks added here should follow the docker-1 convention (mount NAS, point compose at `/mnt/kub/homelab/<svc>/`).

## Komodo management

docker-2 is registered as a Server on docker-3 Komodo Core via a v2 systemd Periphery binary at `/usr/local/bin/periphery`. See [`periphery/README.md`](periphery/README.md) for the install + onboarding runbook.

> **As of 2026-05-14 (Phase 11 plan 11-02):** the Periphery v2 systemd binary is the canonical management plane for docker-2. The legacy `komodo` compose stack on docker-2 (a v1 Periphery container) is left running until plan 11-01c tears down all v1 Komodo state across the fleet per CONTEXT D-20.

## Operator workflow

```bash
# Edit a compose file
vim ~/projects/flux-source/docker-2/<svc>/compose.yaml

# Commit + push to __PRIVATE-REPO__
git -C ~/projects/flux-source add docker-2/<svc>/compose.yaml
git -C ~/projects/flux-source commit -m "feat(<svc>): ..."
git -C ~/projects/flux-source push origin main

# Komodo on docker-3 polls the repo (default 1-hr interval); accelerate via UI
# "Refresh Cache" button on the Stack OR via /write/RefreshStackCache API.
# Then click "Deploy Stack" in docker-3 UI to roll the change.
```

## Security

- Periphery v2 → docker-3 Core: outbound websocket only (port 9120 outbound from docker-2). Periphery does NOT bind any inbound ports (`server_enabled = false`).
- Onboarding keys are single-use (Komodo `OnboardingKey.onboarded` field). After first handshake, the key is rotated off disk on docker-2 AND marked consumed in Core's DB.
- Long-lived Ed25519 keypair at `/etc/komodo/keys/periphery.key` (mode 0600 root) — losing it requires re-onboarding via a fresh key from docker-3 Core UI.
- DO NOT install Periphery on k3s nodes. k3s nodes are managed by Flux/k8s; they have no compose state for Periphery to do anything useful with.
