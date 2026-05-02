# docker-2 mirror plan

Active/active mirror of docker-1 for **stateless web frontends only**.
Stateful services stay singleton on docker-1 — making postgres / Wazuh
indexer / OpenVAS feed-sync / qBittorrent / Maltrail truly active/active
needs replicated state engines (PG streaming repl, OpenSearch cluster,
shared block storage) that are out of scope for a homelab mirror.

## Topology

```
                ┌────────────────────┐
                │ Traefik (k3s)       │
                │ EndpointSlice rr    │
                └─────┬───────┬───────┘
                      │       │
        ┌─────────────┘       └──────────────┐
        │                                    │
   ┌────▼────┐                          ┌────▼────┐
   │ docker-1   │                          │ docker-2   │
   │ __LAN-IP__                         │ 10.10.3.X (TBD)
   │ (singleton + active half)          │ (active half)
   └─────────┘                          └─────────┘

  STATEFUL singletons (docker-1 only):
    wazuh-stack, qbittorrent+gluetun, openvas-stack, maltrail,
    cryptpad, checkmk

  STATELESS active/active (docker-1 + docker-2):
    legacy-vm (webtop is stateless; results in /config can sync)
    drawio  (k3s already, just re-validate)
    netdata-agent (one per host — already DaemonSet shape)
    komodo-periphery (one per host — required pattern)
```

## Provisioning checklist

### 1. VM

| Field | Value |
|---|---|
| name | `docker-2` |
| host | `__PVE-NODE-3__` — auto-picked 2026-05-01 (__PVE-NODE-1__ hosts docker-1; __PVE-NODE-2__/__PVE-NODE-3__ tied on running load 68GiB/20cpu, __PVE-NODE-3__ has no TF-managed resources so cleaner blast separation). Re-evaluate `pvesh get /cluster/resources --type vm` if __PVE-NODE-3__ becomes loaded. |
| ip | `__LAN-IP__` (immediately below docker-1's `.40`) |
| os | Ubuntu 24.04 LTS (matches docker-1; cloned from `ubuntu-tmp` template on __PVE-NODE-1__) |
| cpu | 4 vCPU (docker-1 is 8; mirror runs lighter set) |
| ram | 16 GiB |
| disk | 100 GiB |

Terraform path: extend `terraform/k3s_nodes/` pattern → new module `terraform/dock_nodes/` with the docker-2 spec. Don't reuse `k3s_nodes` since docker-1/docker-2 aren't k3s.

### 2. Bootstrap on docker-2

```bash
# As root on the new VM (cloud-init also installs these, but here for reference):
apt-get update && apt-get install -y docker.io docker-compose-v2 curl jq cifs-utils

# CIFS mount of /mnt/kub (docker-1 uses fstab, not a systemd .mount unit):
# Cloud-init leaves the fstab line commented; uncomment it after scp'ing
# /etc/samba/credentials from docker-1.
# See terraform/dock_nodes/README.md for the full operator runbook.

# Install Komodo Periphery (one Periphery per host).
# Same compose.yaml the docker-1 README documents under "Komodo install on
# docker-1", BUT only the periphery service — Core stays on docker-1.
mkdir -p /opt/komodo
# scp docker-1's /opt/komodo/.env to docker-2 — it carries the shared
# KOMODO_PASSKEY / PERIPHERY_PASSKEYS that authenticates Periphery to
# Core. Same passkey on both hosts is required.
scp bastion@docker-1:/opt/komodo/.env /opt/komodo/.env
chmod 0600 /opt/komodo/.env

cat > /opt/komodo/periphery-only.yaml <<'EOF'
services:
  periphery:
    image: ghcr.io/moghtech/komodo-periphery:latest
    restart: unless-stopped
    env_file: /opt/komodo/.env
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - /proc:/proc:ro
      - keys:/config/keys
volumes:
  keys: {}
EOF
docker compose -f /opt/komodo/periphery-only.yaml up -d
```

### 3. Komodo Core registers docker-2

In the Komodo UI on `http://__LAN-IP__:9120`:

1. **Servers → New** → name `docker-2`, address `http://<docker-2-ip>:8120`,
   passkey from shared `.env`.
2. **Servers → docker-2 → Health** turns green within ~30s.

### 4. Stack assignment

For each stack listed under "STATELESS active/active" above, edit the
Komodo Stack:

- **Server**: change from `docker-1` to `BOTH` (Komodo supports multi-server
  via "Server List"; otherwise duplicate the Stack with `_dock2` suffix
  and a different `project_name`).

For stateful singletons: leave on `docker-1` only.

### 5. Traefik EndpointSlice updates

For each stateless host the mirror covers, add a second endpoint to its
existing bundle:

```yaml
# clusters/default/legacy-vm.yaml example after docker-2 lands:
endpoints:
  - addresses: [__LAN-IP__]   # docker-1
    conditions: { ready: true, serving: true, terminating: false }
  - addresses: [10.10.3.<docker-2>]   # docker-2 — NEW
    conditions: { ready: true, serving: true, terminating: false }
```

Traefik round-robins between endpoints by default. No service-side
config change needed — both backends serve the same content.

### 6. Validation

- `curl -ksSL https://legacy-vm.__BASE-DOMAIN__` repeatedly → traffic should
  bounce between docker-1 and docker-2 (visible in netdata's per-host
  request rate).
- Pull docker-1's network cable / pause container → `legacy-vm.__BASE-DOMAIN__` stays
  up via docker-2.

## Known gotchas

- **Komodo Core stays on docker-1.** Don't run two Cores; single source of
  truth for stack state.
- **Periphery has no host port** on docker-2 either — same security stance
  as docker-1's Periphery.
- **docker-2's `/var/lib/<svc>-data/`** is independent — stateless apps
  shouldn't write to it (use `/mnt/kub/homelab/<svc>/` if any state at
  all). If a stack accidentally writes local state, the two halves
  diverge silently.
- **Dashboard tiles** continue to point at the IngressRoute hostname,
  not at docker-1 or docker-2 directly. No Dashy changes needed for the
  mirror itself.

## Out of scope for v1

- Stateful active/active (Wazuh OpenSearch cluster, Postgres streaming).
- Automatic failover when docker-1 hard-dies (would need a node-fencing
  story; for now Traefik just removes the EndpointSlice address by
  health probe).
- docker-3+. The pattern extends but nothing in this plan is doing it yet.
