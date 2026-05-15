# app-vm — AIL Framework host (Komodo Periphery v2 standalone, doc-only directory)

Phase 11 D-14: app-vm (__LAN-IP__) runs ONLY the AIL Framework as a
**native systemd service** (`app-vm.service`), NOT under docker compose.
Komodo Periphery v2.2.0 IS installed on this host (Phase 11 KOM-01) and
reports it as a Server in Komodo Core (docker-3 — __LAN-IP__) — but there are
zero compose Stacks to register from app-vm (KOM-03 closes via empty-set
Stack registration; see
`.planning/phases/11-komodo-periphery-docker-2-app-vm/11-03-app-vm-inventory.txt`
for the empirical SSH inventory that confirms this).

This directory is **documentation-only**. There are no compose YAML
files committed under `app-vm/`. The files here describe the on-host
Periphery install + onboarding + rotation procedure, and provide a
forward-compatible `.env.example` placeholder schema in case AIL is
ever containerized OR new docker workloads land on app-vm in a later
phase.

> **AIL is NOT docker-compose, AIL is systemd.** AIL's interactive
> bootstrap installs it under `/opt/app-vm/` and runs daemons via
> `LAUNCH.sh -l` wrapped in SCREEN sessions (Redis_AIL, KVROCKS_AIL,
> Script_AIL) under the `bastion` user, optionally fronted by a
> `app-vm.service` systemd unit. See `terraform/app-vm-node/README.md` for
> the AIL install + operational runbook. Manage the running daemons
> via the existing AIL workflow only — Komodo Core has no management
> surface for AIL.

## Layout

```
app-vm/
├── README.md                  # this file
├── .env.example               # forward-compat placeholder (BASE_DOMAIN only)
└── periphery/                 # canonical reference copies of on-host /etc/komodo/* artifacts
    ├── README.md              # Periphery install + onboarding runbook
    ├── periphery.config.toml  # documentation copy of /etc/komodo/periphery.config.toml
    └── periphery.service      # documentation copy of /etc/systemd/system/periphery.service
```

## Periphery install on app-vm

Same battle-tested pattern as docker-1 + docker-2. Install procedure mirrors
`docker-2/periphery/README.md` (which references the canonical procedure in
`docker-1/periphery/README.md`). See `app-vm/periphery/README.md` for the
local copy of the install runbook (SHA256 verification + setup +
systemctl enable + onboarding-key rotation).

Same binary version (v2.2.0) + same SHA256 as docker-1 + docker-2 — see the
version-pin table below.

## KOMODO_ONBOARDING_KEY rotation procedure

Identical procedure to `docker-2/README.md`. After Periphery's first
successful connect to Core (app-vm appears in Komodo Core UI ->
Servers with status Ok), invalidate the onboarding key on BOTH sides
(KOM-01 acceptance per D-12):

1. **On app-vm (remove from disk):**

   ```bash
   ssh bastion@__LAN-IP__
   sudo sed -i.bak '/^onboarding_key[[:space:]]*=/d' /etc/komodo/periphery.config.toml
   grep -E '^[[:space:]]*onboarding_key' /etc/komodo/periphery.config.toml || echo CLEAN
   sudo shred -u /etc/komodo/periphery.config.toml.bak
   sudo systemctl restart periphery
   sudo systemctl status periphery --no-pager | head -5
   ```

2. **In Komodo Core UI (off-host invalidation):**

   Navigate to docker-3 Core UI -> Settings -> Onboarding -> find the
   key by name (e.g., `phase-11-bootstrap-app-vm-2026-05`) -> mark
   consumed / disable. Komodo v2 also auto-marks the key consumed in
   the `OnboardingKey.onboarded` BSON field after first successful
   handshake.

3. **Verify refusal:**

   Try the rotated key against Core via a throwaway curl. Expected:
   response indicates auth failure / key disabled / not found.

## Periphery binary version pin

| Field | Value |
|-------|-------|
| Version | v2.2.0 |
| Source | `https://github.com/moghtech/komodo/releases/download/v2.2.0/periphery-x86_64` |
| SHA256 | `ace9007805dbfe75ad73c75c36bb26852fa909d825577f31f5d13eecd3c52660` |
| Pin date | 2026-05-14 |
| Architecture | x86_64 (single-binary; same hash applies to docker-1, docker-2, app-vm) |

Cross-host audit:

```bash
grep -A8 '## Periphery binary version pin' docker-1/periphery/README.md app-vm/README.md
```

Both tables MUST show the same SHA256 value (same x86_64 build of
v2.2.0 deployed across hosts).

## Security

- **Outbound-mode only** — same shape as docker-2 (no inbound listener;
  `server_enabled = false`).
- **Onboarding key persistence after first connect** — same gotcha as
  docker-2; rotation procedure REQUIRED for KOM-01 acceptance.
- **systemctl enable required** — same gotcha; upstream
  `setup-periphery.py` runs `systemctl start` but NOT `systemctl
  enable`. Periphery dies on reboot if not enabled.
- **No SSH key / no PAT on disk on app-vm** — git auth flows through
  Core's GitProviderAccount (RESEARCH.md Q3). app-vm's Periphery only
  needs network reachability to docker-3:9120.
- **AIL data isolation** — Periphery sees `/var/run/docker.sock` +
  `/proc` only. AIL data lives at `/opt/app-vm/` which is NOT exposed
  because no compose workload mounts it. AIL runtime remains
  operator-managed via the SCREEN sessions documented in
  `terraform/app-vm-node/README.md`. Komodo Core has no visibility into
  AIL's processes.

## Troubleshooting

- **app-vm shows offline in Core UI:**

  ```bash
  ssh bastion@__LAN-IP__ 'sudo systemctl status periphery --no-pager; sudo journalctl -u periphery -n 50 --no-pager'
  ```

- **Periphery logs `Failed to refresh container stats cache` ERROR
  every cycle:** expected and acceptable per D-14 — docker is NOT
  installed on app-vm. The `container_stats_polling_rate = "1-hr"`
  knob in `periphery.config.toml` throttles this to once per hour
  (see `app-vm/periphery/periphery.config.toml`).
- **Periphery active but `is-active` returns failed after reboot:**
  most likely `systemctl enable periphery` was skipped — re-run it.
- **AIL down:** out of scope for this directory. See
  `terraform/app-vm-node/README.md` for AIL operational procedures.
