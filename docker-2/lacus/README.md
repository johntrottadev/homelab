# Lacus on docker-2

Capture system used by the AIL Framework's crawler subsystem (and standalone
clients) to fetch + render URLs through Playwright/Chromium. Single-container
service: a bundled Valkey (job queue) runs inside the same image, started
by `entrypoint.sh` before `supervisord` launches the Lacus website + capture
manager.

## Why docker-2 (not k3s, not docker-1)

- **Upstream ships `docker-compose.yml`** — no maintained Helm/k8s artifact.
- Playwright + headless Chromium is the same workload class as the openvas
  browser stack on docker-1 — keeping browser-driven workloads off k3s avoids
  Chromium-in-pod headaches (font fallbacks, sandbox needs, eviction).
- docker-1 is already heavy (openvas, maltrail, wazuh, qbittorrent, cryptpad,
  checkmk). docker-2 has ~30 GiB free RAM at deploy time — comfortable home
  for Lacus's ~2-3 GiB working set.

## Routing

`https://lacus.__BASE-DOMAIN__` → Traefik → `http://__LAN-IP__:7100` (HTTP capture
API). AIL on `__LAN-IP__` talks to Lacus directly at the IP, not through
Traefik. See `clusters/default/lacus.yaml` for the bundle.

`:7101` (Tactus interactive xpra) is bound to `127.0.0.1` inside the compose
on purpose — it's only used for in-container interactive captures, no need
for LAN exposure.

## Persistence

| Mount | Purpose | Backed up by |
|---|---|---|
| `./config` (bind) | `generic.json` — capture limits, retention | docker-2 kopia (`/opt/stacks` is in `/etc/kopia/sources.list`) |
| `lacus_cache` (named) | Valkey AOF + in-flight job state | docker-2 kopia (`/var/lib/docker/volumes` is in sources) |

No Velero coverage — Lacus is a docker workload, not a k8s namespace.

## First-run

```bash
# 1. Build the image (~15 min — Valkey from source + playwright + chromium)
ssh bastion@__LAN-IP__ 'cd /opt/stacks/lacus && docker compose build'

# 2. Seed ./config from inside the image. The bind mount otherwise masks
#    the image's /app/lacus/config dir, which contains *.json.sample files
#    Lacus needs at startup. Skip this and the container CrashLoops with
#    "FileNotFoundError: /app/lacus/config/logging.json.sample".
ssh bastion@__LAN-IP__ '
  docker create --name lacus-cfg-extract lacus-lacus:latest
  docker cp lacus-cfg-extract:/app/lacus/config/. /opt/stacks/lacus/config/
  docker rm lacus-cfg-extract
'

# 3. Start
ssh bastion@__LAN-IP__ 'cd /opt/stacks/lacus && docker compose up -d'
```

Verify:

```bash
curl -s http://__LAN-IP__:7100/   # returns Lacus status JSON
```

## AIL ↔ Lacus wiring

AIL reads `lacus_url` from `configs/core.cfg` `[Crawler]` section. The
`terraform/app-vm-node/cloud-init/app-vm-install.sh` script sets this to
`http://__LAN-IP__:7100` automatically on install. To change after install,
edit `/opt/app-vm/configs/core.cfg` on app-vm and `LAUNCH.sh -k && LAUNCH.sh -l`.

## Vendored from upstream

`Dockerfile`, `entrypoint.sh`, and `supervisord/supervisord.conf` are
verbatim from `app-vm-project/lacus@main` as of 2026-05-04. Re-pull periodically
to track upstream:

```bash
curl -fsSL https://raw.githubusercontent.com/app-vm-project/lacus/main/Dockerfile > Dockerfile
curl -fsSL https://raw.githubusercontent.com/app-vm-project/lacus/main/entrypoint.sh > entrypoint.sh
curl -fsSL https://raw.githubusercontent.com/app-vm-project/lacus/main/supervisord/supervisord.conf > supervisord/supervisord.conf
```

Diff against the local copy and rebuild if anything changed. Local
`compose.yaml` is *not* upstream (we add bind mount path + Tactus
loopback-only binding + Komodo-friendly project name).
