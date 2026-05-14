# docker-3 — Komodo Core v2 public-facing host (Phase 11 11-01a)

docker-3 (__LAN-IP__) runs Komodo Core v2 as a fresh-state host provisioned in
Phase 11 after the in-place v1.19.5 -> v2.2.0 bump on docker-1 was rolled back
(D-21, `11-01-ROLLBACK.md`). docker-3 hosts Core only — no embedded Periphery,
no workload stacks. Periphery agents on docker-1, docker-2, and app-vm connect
outbound to docker-3:9120 via Ed25519 PKI (D-01, D-17, D-18).

The legacy v1 Komodo Core on docker-1 remains on v1.19.5 until parity is
verified (D-20). Decommission procedure is in Plan 11-01c.

## Layout

```
docker-3/
├── README.md          # this file
├── komodo-stack.yaml  # Komodo Core v2 bootstrap — Core + FerretDB + Postgres (run on docker-3 once)
└── .env.example       # per-host env schema (operator copies to /opt/komodo/.env, fills secrets)
```

docker-3 has no workload subdirs — it runs Core only.

## What flux does NOT do

The k3s Flux Kustomization at `clusters/default/kustomization.yaml` is
explicit-list and MUST NOT include `docker-3/*`. Flux only manages k3s.
Komodo manages docker-3.

## NAS path convention

All docker-3 service state lives under `/mnt/kub/homelab/komodo-docker-3/` (NAS-backed,
CIFS-mounted to docker-3). The `-docker-3` suffix distinguishes docker-3's Komodo paths
from docker-1's `/mnt/kub/homelab/komodo/`. Mirrors the convention used by k3s
NFS PVs at `/volume1/kub/homelab/<app>/`.

## Komodo install on docker-3

See `komodo-stack.yaml` (Postgres + FerretDB + Komodo Core). Run once on docker-3 host:

```bash
ssh bastion@__LAN-IP__
sudo mkdir -p /opt/komodo /var/lib/komodo/backups /etc/komodo
sudo chown -R bastion:bastion /opt/komodo
sudo mkdir -p /mnt/kub/homelab/komodo-docker-3
cd /opt/komodo

# Fetch the bootstrap compose from the operator workstation (preferred) or
# `gh api ... contents/...` (works while authenticated to gh):
# (run from workstation)
# scp docker-3/komodo-stack.yaml bastion@__LAN-IP__:/opt/komodo/

# Author /opt/komodo/.env — operator generates random secrets here.
# This file is NEVER committed. Per feedback_password_handling: write to file
# path on host; never paste cleartext into chat.
umask 0077
cat > .env <<EOF
KOMODO_DATABASE_USERNAME=admin
KOMODO_DATABASE_PASSWORD=$(openssl rand -base64 32 | tr -d '=+/' | head -c 32)

KOMODO_HOST=http://__LAN-IP__:9120
KOMODO_TITLE=bastion-docker-3

KOMODO_LOCAL_AUTH=true
KOMODO_INIT_ADMIN_USERNAME=admin
KOMODO_INIT_ADMIN_PASSWORD=$(openssl rand -base64 24 | tr -d '=+/' | head -c 24)
KOMODO_FIRST_SERVER_NAME=docker-3

KOMODO_JWT_SECRET=$(openssl rand -hex 32)
KOMODO_WEBHOOK_SECRET=$(openssl rand -hex 32)

KOMODO_MONITORING_INTERVAL=15-sec
KOMODO_RESOURCE_POLL_INTERVAL=1-hr

KOMODO_DISABLE_USER_REGISTRATION=true
TZ=America/New_York
EOF
chmod 0600 .env

# Save admin creds to a place the operator can reach (NAS, mode 0600 via
# DSM ACL) but NEVER paste cleartext in chat / commit messages.
ADMIN_PW=$(grep '^KOMODO_INIT_ADMIN_PASSWORD=' .env | cut -d= -f2-)
echo "$ADMIN_PW" | sudo tee /mnt/kub/homelab/komodo-docker-3/admin_initial_password.txt > /dev/null
sudo chmod 0600 /mnt/kub/homelab/komodo-docker-3/admin_initial_password.txt
unset ADMIN_PW

docker compose -f komodo-stack.yaml up -d
```

> **AVX caveat:** docker-3 is a ProxMox VM with the default qemu64 CPU
> model. `/proc/cpuinfo` shows "QEMU Virtual CPU version 2.5+" and no AVX
> flag. MongoDB 5.0+ crashes with "Illegal instruction (core dumped)"
> immediately under that CPU model. This is why the bootstrap uses
> FerretDB (Postgres-backed Mongo-wire) per Komodo's official no-AVX path,
> not MongoDB. Fixing the qemu64 → host CPU model is filed as a future
> hardening item.

Komodo Core UI: `http://__LAN-IP__:9120` (LAN/tailnet only — no DNS, no
firewall NAT). Log in with `admin` / the value at
`/mnt/kub/homelab/komodo-docker-3/admin_initial_password.txt`. Rotate the admin
password via UI immediately after first login.

## Security

- **Core has no Periphery on this host** — docker-3 is Core-only. Periphery on
  docker-1/docker-2/app-vm connects outbound to docker-3:9120 via Ed25519 PKI (D-01,
  D-17, D-18). Onboarding is covered in Plans 11-01b, 11-02, 11-03.
- **FerretDB/Postgres have no host port** — internal-only on the docker bridge.
  Mongo-wire `27017` and Postgres `5432` are never exposed outside the compose
  network.
- **Komodo GitHub PAT** (for cloning private repos) is stored via the
  Komodo UI under Settings → Git Providers, encrypted at rest in FerretDB.
  NOT in `/opt/komodo/.env` and NOT in git. See D-16 (Branch B PAT fallback).
- **DO NOT install Periphery on k3s nodes** — Periphery mounts the
  docker socket and `/proc`. On a cluster node it would have full
  control of containerd. See docker-1/README.md for the full rationale.
- **Image pinning:** all images (postgres-documentdb, ferretdb, komodo-core)
  are pinned by sha256 digest in `komodo-stack.yaml`. No `:latest` or semver
  tag drift.

## v1 Core decommission on docker-1

The legacy v1 Komodo Core on docker-1 (`docker-1/komodo-stack.yaml`) is decommissioned
after Phase 11 parity is verified per CONTEXT D-20. docker-1's volumes will be
renamed `*.retired-v1-YYYYMMDDtHHMMZ` for 30d forensic preservation. See
`.planning/phases/11-komodo-periphery-docker-2-app-vm/11-01c-decommission-v1-core-on-docker-1-PLAN.md`.

## Troubleshooting

- "Core container won't start" → check `docker compose -f /opt/komodo/komodo-stack.yaml logs core`.
  Common causes: malformed `.env` (missing required vars), digest mismatch if image
  was re-tagged upstream (pin is correct; re-pull with `docker compose pull`).
- "FerretDB fails to start" → check Postgres is healthy first:
  `docker compose -f /opt/komodo/komodo-stack.yaml logs postgres`.
- "Env file missing on docker-3" → verify CIFS mount: `mount | grep /mnt/kub`.
  If unmounted: `sudo mount -a` (fstab entry was written by bootstrap.sh).
- "Admin password unknown" → value is at
  `/mnt/kub/homelab/komodo-docker-3/admin_initial_password.txt` (NAS-backed).
  If rotated via UI and forgotten, reset via FerretDB:
  `docker compose exec -T ferretdb mongosh komodo --eval 'db.Users.find({},{username:1,password:1})'`
  (then update the hash or delete + recreate the user via Komodo UI).
