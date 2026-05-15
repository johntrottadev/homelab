# app-vm Periphery v2 — install runbook

Komodo Periphery v2.2.0 native systemd binary on app-vm (__LAN-IP__),
outbound to docker-3 Komodo Core (http://__LAN-IP__:9120) via Ed25519 PKI.

Authored by Phase 11 plan 11-03 (install) + 11-04 (this doc directory),
2026-05-14.

## Periphery binary version pin

Single-binary fleet across docker-1, docker-2, app-vm — see
[`../README.md`](../README.md) for the canonical version-pin table. As
of 2026-05-14 the same v2.2.0 binary (SHA256
`ace9007805dbfe75ad73c75c36bb26852fa909d825577f31f5d13eecd3c52660`) is
deployed on app-vm.

## On-host paths

Same as docker-2's layout:

| Path | Purpose |
|------|---------|
| `/usr/local/bin/periphery` | Binary (mode 0755, root:root) |
| `/etc/komodo/periphery.config.toml` | Config (mode 0600, root:root, no `onboarding_key` after rotation) |
| `/etc/komodo/keys/periphery.key` + `.pub` | Long-lived Ed25519 keypair (auto-generated on first start) |
| `/etc/komodo/keys/core.pub` | docker-3 Core's pubkey captured at onboarding |
| `/etc/systemd/system/periphery.service` | systemd unit (manual; written by install procedure, NOT setup-periphery.py — see app-vm/periphery/periphery.service for canonical content) |

## First-run install (one time on app-vm)

```bash
# 1. Mint an onboarding key in Komodo Core UI on docker-3
#    Navigate: docker-3 Core UI -> Settings -> Onboarding -> Create
#    Name: phase-11-bootstrap-app-vm-<YYYY-MM> (one key per host;
#          earlier keys for docker-1/docker-2 were rotated at end of their
#          respective install plans)

# 2. Pre-verify the binary's SHA256 on the operator workstation BEFORE installing
cd /tmp
curl -sSLfO https://github.com/moghtech/komodo/releases/download/v2.2.0/periphery-x86_64
shasum -a 256 periphery-x86_64
# Confirm against the SHA256 in ../README.md "Periphery binary version pin"
# (which equals the SHA256 in docker-1/periphery/README.md and docker-2/periphery/README.md).

# 3. scp binary + key to app-vm (via bastion LXC bastion if direct workstation
#    upload is not desired — same pattern as docker-1/docker-2 install)
scp periphery-x86_64 bastion@__LAN-IP__:/tmp/

# 4. SSH to app-vm + install
ssh bastion@__LAN-IP__
sudo install -m 0755 /tmp/periphery-x86_64 /usr/local/bin/periphery
sudo shasum -a 256 /usr/local/bin/periphery
# Expect: ace9007805dbfe75ad73c75c36bb26852fa909d825577f31f5d13eecd3c52660

# 5. Write config (with one-time onboarding_key) — see app-vm/periphery/periphery.config.toml
#    for the canonical shape; write the live file at /etc/komodo/periphery.config.toml
#    with `onboarding_key = "O-..."` line ADDED for first handshake.
sudo install -d -m 0700 /etc/komodo
sudo install -d -m 0700 /etc/komodo/keys
sudo nano /etc/komodo/periphery.config.toml   # mode 0600 root:root
sudo chmod 0600 /etc/komodo/periphery.config.toml

# 6. Write systemd unit (verbatim from app-vm/periphery/periphery.service)
sudo nano /etc/systemd/system/periphery.service
sudo systemctl daemon-reload

# 7. Enable + start
sudo systemctl enable periphery
sudo systemctl start periphery
sudo systemctl status periphery --no-pager | head -10

# 8. Verify Periphery connected to Core
sudo journalctl -u periphery -n 20 --no-pager | grep -E 'Logged in|websocket'
# Expect: "Logged in to Komodo Core __LAN-IP__:9120 websocket as Server app-vm"

# 9. ROTATE the onboarding key — see ../README.md "KOMODO_ONBOARDING_KEY rotation procedure"
sudo sed -i.bak '/^onboarding_key[[:space:]]*=/d' /etc/komodo/periphery.config.toml
grep -E '^[[:space:]]*onboarding_key' /etc/komodo/periphery.config.toml || echo CLEAN
sudo shred -u /etc/komodo/periphery.config.toml.bak
sudo systemctl restart periphery
sudo journalctl -u periphery -n 5 --no-pager | grep -E 'Logged in|websocket'
```

## Stacks managed by this Periphery

(none) — D-14 doc-only. AIL runs as systemd, not docker-compose. Plan
11-03 SSH inventory empirically confirmed zero `docker compose ls`
projects (in fact, docker is not installed on app-vm). Komodo Server
registration for app-vm is the entirety of KOM-01 closure for this
host; KOM-03 for app-vm closes via empty-set Stack registration.

If a containerized workload ever lands on app-vm in a later phase,
register it as a Komodo Stack at that time and update the table in
this README to mirror the docker-1/docker-2 pattern (`Stack name |
project_name | compose path`).

## app-vm-specific notes (D-14)

- **No docker daemon present.** Periphery's `container_stats` poller
  logs an ERROR every cycle about the missing `/var/run/docker.sock`;
  `container_stats_polling_rate = "1-hr"` throttles this to acceptable
  noise. Komodo v2.2.0 doesn't expose a "disable container stats"
  toggle.
- **Periphery is here for host visibility only** — fleet-wide CPU /
  mem stats + ssh-exec audits surface in the single docker-3 Core UI for
  app-vm alongside docker-1 and docker-2.
- **Do NOT install Periphery on the k3s nodes.** Pitfall 8 — cluster
  destabilization risk; Periphery mounts `/var/run/docker.sock` and
  `/proc`. k3s nodes are managed by Flux, not Komodo.

## Reference: on-host artifact paths

| Artifact | On-host path | Repo reference copy |
|----------|--------------|--------------------|
| Binary | `/usr/local/bin/periphery` | (none — binary not committed) |
| Config | `/etc/komodo/periphery.config.toml` | `app-vm/periphery/periphery.config.toml` (doc only) |
| Systemd unit | `/etc/systemd/system/periphery.service` | `app-vm/periphery/periphery.service` (doc only) |
| Long-term Ed25519 key | `/etc/komodo/keys/periphery.key` | (none — auto-generated; never leaves host) |

## See also

- [`../README.md`](../README.md) — host-level app-vm runbook
- [`../../docker-1/periphery/README.md`](../../docker-1/periphery/README.md) — canonical install procedure (use the same script with `connect_as = "app-vm"` and the app-vm onboarding key)
- [`../../docker-2/periphery/README.md`](../../docker-2/periphery/README.md) — sibling-host install runbook
- [`../../docker-3/README.md`](../../docker-3/README.md) — Core host that this Periphery talks to
- [`../../terraform/app-vm-node/README.md`](../../terraform/app-vm-node/README.md) — AIL Framework operational runbook (the only workload on app-vm)
