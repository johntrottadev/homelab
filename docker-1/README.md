# docker-1 — docker-compose GitOps via Komodo

Phase 999.2 Wave 5 sub-deliverable. flux-source extends to cover
non-k8s services on docker-1 (__LAN-IP__). Komodo Core+Periphery on docker-1
polls this directory and reconciles compose stacks defined under
`docker-1/<service>/compose.yaml`.

## Layout

```
docker-1/
├── README.md                  # this file
├── .gitignore                 # excludes *.env, secrets, Komodo runtime data
├── komodo-stack.yaml          # Komodo Core+Periphery bootstrap (run on docker-1 once)
└── wazuh/
    ├── compose.yaml           # vendored from bastion/services/wazuh/docker-compose.yml
    └── deploy.sh              # vendored from bastion/services/wazuh/deploy.sh — Komodo pre-deploy hook
```

## What flux does NOT do

The k3s Flux Kustomization at `clusters/default/kustomization.yaml` is
explicit-list and MUST NOT include `docker-1/*`. Flux only manages k3s.
Komodo manages docker-1.

## NAS path convention

All docker-1 service state — compose trees, configs, certs, env files,
secrets — lives under `/mnt/kub/homelab/<service>/` (NAS-backed,
CIFS-mounted to docker-1). Mirrors the convention used by k3s NFS PVs at
`/volume1/kub/homelab/<app>/`. Wazuh moved here on 2026-04-30 from
`/mnt/kub/wazuh/` to fit.

## Bind-mount path convention (read this before vendoring a new service)

Komodo invokes `docker compose up -d` from its workspace clone (e.g.
`/etc/komodo/stacks/<stack>/`), NOT from the canonical NAS data dir.
Compose files vendored here MUST use absolute bind-mount paths
(`/mnt/kub/homelab/<svc>/...`), not relative `./config/...`.

The single-line transform from upstream-vendored compose:
```
- ./config/wazuh_indexer/internal_users.yml:/usr/share/.../internal_users.yml
+ /mnt/kub/homelab/wazuh/single-node/config/wazuh_indexer/internal_users.yml:/usr/share/.../internal_users.yml
```

Same rule applies to pre-deploy scripts: `cd "$(dirname "$0")"` becomes
`cd /mnt/kub/homelab/<svc>/...` (absolute).

## Komodo Stack configuration

In Komodo UI, create a Stack resource for Wazuh:

| Field | Value |
|---|---|
| name | `wazuh-single-node` |
| project_name | `single-node` (matches existing `single-node-wazuh.*` containers — adopts in place) |
| git_provider | `github.com` |
| repo | `johntrottadev/homelab` |
| branch | `main` |
| file_paths | `[docker-1/wazuh/compose.yaml]` |
| env_file_path | `/mnt/kub/homelab/wazuh/single-node/.env` |
| poll_for_updates_interval | `1-min` |
| deploy_strategy | `docker compose up -d` |
| pre_deploy | `bash docker-1/wazuh/deploy.sh` |

## Secrets

Secrets NEVER land in this directory. Compose files use `${VAR}`
interpolation; Komodo passes `--env-file /mnt/kub/homelab/<svc>/.env` at
deploy.

For Wazuh:
- Env file: `/mnt/kub/homelab/wazuh/single-node/.env` (NAS, CIFS-auth + DSM ACL)
- Password file: `/mnt/kub/homelab/wazuh/secrets/passwords.txt` (NAS, same)
- Read flow: see `~/projects/bastion/services/wazuh/README.md`

> **CIFS mount caveat:** the share is mounted with `file_mode=0755` baked
> into mount options. `chmod 0600` on `.env` is reported as 0755 by
> Linux but real protection comes from CIFS auth + DSM-side share
> permissions. Cleartext never leaves the NAS via git.

## Operator workflow

```bash
# Edit a compose file
vim ~/projects/flux-source/docker-1/wazuh/compose.yaml

# Push
cd ~/projects/flux-source
git add docker-1/wazuh/compose.yaml
git commit -m "feat(wazuh): bump indexer image to X.Y.Z"
git push origin main

# Komodo polls within 1-min interval and runs:
#   bash docker-1/wazuh/deploy.sh
#   docker compose --env-file /mnt/kub/homelab/wazuh/single-node/.env up -d
```

## Migration of additional docker-1 services

This phase delivers Wazuh + Komodo bootstrap only. Other docker-1
containers visible at cutover (qbittorrent + gluetun) are intentionally
deferred to a future 999.4-or-later phase per Pitfall 7 (scope creep).

When migrating each next service:
1. Move state under `/mnt/kub/homelab/<svc>/` if not already
2. Vendor the compose with absolute bind-mount paths (see "Bind-mount
   path convention" above)
3. Add a Stack resource in Komodo UI with `project_name` matching the
   existing container set so adoption is in-place (no parallel containers)

## Komodo install on docker-1

See `komodo-stack.yaml` (Postgres + FerretDB + Komodo Core + Periphery
bootstrap). Run once on docker-1 host:

```bash
ssh bastion@__LAN-IP__
sudo mkdir -p /opt/komodo /var/lib/komodo/backups /etc/komodo
sudo chown -R bastion:bastion /opt/komodo
sudo mkdir -p /mnt/kub/homelab/komodo
cd /opt/komodo

# Fetch the bootstrap compose. The repo is private, so use scp from the
# operator workstation (preferred) or `gh api ... contents/...` (works
# while the operator is authenticated to gh):
scp ~/projects/flux-source/docker-1/komodo-stack.yaml bastion@__LAN-IP__:/opt/komodo/

# Author /opt/komodo/.env — operator generates random secrets here.
# This file is NEVER committed. docker-1/.gitignore excludes *.env at the
# docker-1/ tree root, but to be safe the file lives outside the git tree.
umask 0077
PK=$(openssl rand -hex 32)
cat > .env <<EOF
# Postgres / FerretDB DB credentials (internal only; no host port exposed)
KOMODO_DATABASE_USERNAME=admin
KOMODO_DATABASE_PASSWORD=$(openssl rand -base64 32 | tr -d '=+/' | head -c 32)

# Komodo Core public-facing host (LAN/tailnet) — used for OAuth / webhook
# URL suggestion in the UI. Plain HTTP is fine for LAN-only.
KOMODO_HOST=http://__LAN-IP__:9120
KOMODO_TITLE=bastion-docker-1

# Local-auth bootstrap admin (rotate via UI on first login)
KOMODO_LOCAL_AUTH=true
KOMODO_INIT_ADMIN_USERNAME=admin
KOMODO_INIT_ADMIN_PASSWORD=$(openssl rand -base64 24 | tr -d '=+/' | head -c 24)
KOMODO_FIRST_SERVER_NAME=docker-1

# Random secrets for token signing + inbound webhook auth
KOMODO_JWT_SECRET=$(openssl rand -hex 32)
KOMODO_WEBHOOK_SECRET=$(openssl rand -hex 32)

# Shared passkey for Core <-> Periphery auth.
# Both services read this from env_file. The auto-keypair flow with
# KOMODO_PERIPHERY_PUBLIC_KEY=file:/config/keys/periphery.pub requires
# manual seeding of the keys volume; passkey is the simpler equivalent
# for a single-host setup.
KOMODO_PASSKEY=$PK
PERIPHERY_PASSKEYS=$PK

# Sensible polling defaults
KOMODO_MONITORING_INTERVAL=15-sec
KOMODO_RESOURCE_POLL_INTERVAL=1-hr

# Lock down public registration
KOMODO_DISABLE_USER_REGISTRATION=true
TZ=America/New_York
EOF
chmod 0600 .env
unset PK

# Save admin creds to a place the operator can reach (NAS, mode 0600 via
# DSM ACL) but NEVER paste cleartext in chat / commit messages.
ADMIN_PW=$(grep '^KOMODO_INIT_ADMIN_PASSWORD=' .env | cut -d= -f2-)
echo "$ADMIN_PW" | sudo tee /mnt/kub/homelab/komodo/admin_initial_password.txt > /dev/null
sudo chmod 0600 /mnt/kub/homelab/komodo/admin_initial_password.txt
unset ADMIN_PW

sudo docker compose -f komodo-stack.yaml up -d
```

> **AVX caveat:** docker-1 runs as a ProxMox VM with the default qemu64 CPU
> model. `/proc/cpuinfo` shows "QEMU Virtual CPU version 2.5+" and no AVX
> flag. MongoDB 5.0+ crashes with "Illegal instruction (core dumped)"
> immediately under that CPU model. This is why the bootstrap uses
> FerretDB (Postgres-backed Mongo-wire) per Komodo's official no-AVX path,
> not MongoDB. Fixing the qemu64 → host CPU model is filed as a future
> hardening item.

Komodo Core UI: `http://__LAN-IP__:9120` (LAN/tailnet only — no DNS, no
firewall NAT). Log in with `admin` / the value at
`/mnt/kub/homelab/komodo/admin_initial_password.txt`. Rotate the admin
password via UI immediately after first login.

## Security

- **Periphery has no host port** — only reachable on the docker bridge
  from Core (`periphery:8120`). Strictly stronger than the plan's
  proposed `127.0.0.1:8120` localhost-bind.
- **Core ↔ Periphery auth:** auto-generated keypair in a shared docker
  volume (`keys`). Core writes `KOMODO_PERIPHERY_PUBLIC_KEY=file:/config/keys/periphery.pub`;
  Periphery's private key never leaves the volume. Asymmetric, no
  shared secret.
- **MongoDB** has no host port — internal-only on the docker bridge.
- **Komodo GitHub PAT** (for cloning private repos) is stored via the
  Komodo UI under Settings → Git Providers, encrypted at rest in mongo.
  NOT in `/opt/komodo/.env` and NOT in git.
- **DO NOT install Periphery on k3s nodes** — Periphery mounts the
  docker socket and `/proc`. On a cluster node it would have full
  control of containerd. Periphery belongs on docker-1 only.
- **Image pinning:** all 3 images (mongo, komodo-core, komodo-periphery)
  are pinned by sha256 digest in `komodo-stack.yaml`. T-999.2-07
  mitigated regardless of upstream tag drift.

## Troubleshooting

- "Stack not deploying" → Komodo UI → Stack → logs panel.
- "Env file missing on docker-1" → verify CIFS mount: `mount | grep /mnt/kub`.
- "Wazuh state lost" → Wazuh hot data lives in `/var/lib/wazuh-data/`
  on docker-1 SSD (NOT the NAS); cold/config in `/mnt/kub/homelab/wazuh/`.
  Restart preserves data; backup the NAS tree at `/volume1/kub/homelab/wazuh/`.
- "Containers duplicated after Komodo took over" → `project_name`
  mismatch. Set Komodo Stack `project_name: single-node` to adopt the
  existing container set; otherwise `compose down` the old project first.
