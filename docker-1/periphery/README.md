# docker-1 Periphery v2 — install runbook

Komodo Periphery v2.2.0 native systemd binary on docker-1 (__LAN-IP__), outbound to docker-3 Komodo Core (http://__LAN-IP__:9120) via Ed25519 PKI.

Authored by Phase 11 plan 11-01b (2026-05-14). The legacy v1 embedded Periphery inside `docker-1/komodo-stack.yaml` coexists during the migration window; its decommission is gated on parity in plan 11-01c.

## Periphery binary version pin

| Field | Value |
|-------|-------|
| Version | v2.2.0 |
| Source | `https://github.com/moghtech/komodo/releases/download/v2.2.0/periphery-x86_64` |
| SHA256 | `ace9007805dbfe75ad73c75c36bb26852fa909d825577f31f5d13eecd3c52660` |
| Pin date | 2026-05-14 |
| Architecture | x86_64 (single-binary; same hash applies to docker-2, app-vm) |

When bumping: download new binary, capture its SHA256, update this table + the equivalent rows in `docker-2/periphery/README.md` and `app-vm/periphery/README.md`, scp to all three hosts under `/usr/local/bin/periphery`, restart `periphery.service`.

## On-host paths

| Path | Purpose | Mode | Owner |
|------|---------|------|-------|
| `/usr/local/bin/periphery` | Binary | 0755 | root:root |
| `/etc/komodo/periphery.config.toml` | Config (no onboarding_key after rotation) | 0600 | root:root |
| `/etc/komodo/keys/periphery.key` | Long-lived Ed25519 private key | 0600 | root:root |
| `/etc/komodo/keys/periphery.pub` | Local pubkey companion | 0600 | root:root |
| `/etc/komodo/keys/core.pub` | docker-3 Core's pubkey (captured during onboarding) | 0600 | root:root |
| `/etc/systemd/system/periphery.service` | systemd unit | 0644 | root:root |

The committed docs copies at `docker-1/periphery/periphery.config.toml` and `docker-1/periphery/periphery.service` are the structural reference — they NEVER carry the `onboarding_key` value or any private key material.

## First-time install (the procedure plan 11-01b executed)

```bash
# 1. From operator workstation: download + SHA256-verify the binary
curl -sSLfO https://github.com/moghtech/komodo/releases/download/v2.2.0/periphery-x86_64
shasum -a 256 periphery-x86_64
# expect: ace9007805dbfe75ad73c75c36bb26852fa909d825577f31f5d13eecd3c52660

# 2. scp + verify on docker-1 (defense in depth)
scp periphery-x86_64 bastion@__LAN-IP__:/tmp/periphery
ssh bastion@__LAN-IP__ 'sudo install -m 0755 -o root -g root /tmp/periphery /usr/local/bin/periphery && sudo sha256sum /usr/local/bin/periphery && rm /tmp/periphery'

# 3. Mint a single-use onboarding key in docker-3 Core (Settings -> Onboarding -> Create)
#    Stage it on docker-1 via the pattern below — NEVER paste the O_... value into chat
#    or shell history. Drop it directly into the file from your password manager.
ssh bastion@__LAN-IP__ 'sudo bash -c "umask 077; mkdir -p /etc/komodo; cat > /etc/komodo/periphery.onboarding-key; chmod 0600 /etc/komodo/periphery.onboarding-key"' < /tmp/onboard-key.txt
# (or use the orchestrator-driven path in 11-01b: scp from workstation /tmp file mode 600)

# 4. Author /etc/komodo/periphery.config.toml (inlining the onboarding_key for first handshake).
#    Use the structural shape committed at docker-1/periphery/periphery.config.toml plus the
#    onboarding_key value read from /etc/komodo/periphery.onboarding-key.

# 5. Author /etc/systemd/system/periphery.service from the committed docs copy.

# 6. Enable + start
ssh bastion@__LAN-IP__ 'sudo systemctl daemon-reload && sudo systemctl enable --now periphery'

# 7. Verify in docker-3 Core: docker-1 appears as a Server, status Ok/Online.

# 8. Rotate the onboarding key off disk (single-use)
ssh bastion@__LAN-IP__ 'sudo sed -i "/^onboarding_key/d" /etc/komodo/periphery.config.toml && sudo shred -u /etc/komodo/periphery.onboarding-key && sudo systemctl restart periphery'
# Verify config no longer has onboarding_key; verify periphery reconnects without it.
```

## Operational

| What | How |
|------|-----|
| Status | `sudo systemctl status periphery` |
| Logs (live) | `sudo journalctl -u periphery -f` |
| Logs (recent) | `sudo journalctl -u periphery --since '1 hour ago'` |
| Restart | `sudo systemctl restart periphery` |
| Stop | `sudo systemctl stop periphery` (Komodo UI will show Server offline) |
| Verify connection | `sudo journalctl -u periphery -n 20 \| grep 'Logged in'` |

## v1 → v2 coexistence

docker-1 currently runs BOTH:

- **Legacy v1 Komodo Core + embedded Periphery** in `/opt/komodo/komodo-stack.yaml` (docker-compose stack). The v1 Periphery is inside that compose stack's `periphery` service; it talks to its co-located v1 Core at `__LAN-IP__:9120` using the legacy `KOMODO_PASSKEY` env var.
- **New v2 systemd Periphery** at `/usr/local/bin/periphery`. Talks outbound to docker-3 v2 Core at `__LAN-IP__:9120` via Ed25519 PKI handshake.

The two Peripheries do NOT conflict — different ports, different processes, different auth. The new v2 Periphery is the one Komodo's docker-3 UI uses to manage docker-1's stacks going forward.

Decommission of the v1 Core stack on docker-1 is a separate step (Plan 11-01c) gated on full Wave-2 parity per CONTEXT D-20.

## See also

- [`docker-1/README.md`](../README.md) — host-level docker-1 runbook (NAS paths, stack inventory, secrets)
- [`docker-1/komodo-stack.yaml`](../komodo-stack.yaml) — legacy v1 Komodo Core compose stack (still running; decommissioned in 11-01c)
- [`docker-3/README.md`](../../docker-3/README.md) — docker-3 Core (the Periphery's outbound target)
- `.planning/phases/11-komodo-periphery-docker-2-app-vm/11-01b-migrate-docker-1-periphery-and-stacks-to-docker-3-PLAN.md` — full plan record
