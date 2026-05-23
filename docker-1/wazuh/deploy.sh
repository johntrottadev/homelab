#!/usr/bin/env bash
# Vendored from bastion/services/wazuh/deploy.sh on 2026-04-30.
# Phase 999.2 Wave 5: Komodo invokes this as pre-deploy hook to template
# config/wazuh_dashboard/wazuh.yml (TRUNCATE in-place to preserve inode for
# the bind-mount), then docker compose up -d.
#
# DEVIATION FROM VERBATIM VENDOR: cd target is now ABSOLUTE
#   `cd "$(dirname "$0")"` -> `cd /mnt/kub/homelab/wazuh/single-node`
# Reason: Komodo invokes this script from its workspace clone (e.g.
# /etc/komodo/stacks/<stack>/docker-1/wazuh/deploy.sh). The relative form
# would template a wazuh.yml inside the clone instead of the canonical
# NAS data dir, so the dashboard's bind-mounted config would never see
# rotated credentials. Absolute cd makes the script invocation-agnostic.
#
# Usage on docker-1 (manual fallback if Komodo is unavailable):
#   /path/to/deploy.sh   # cd is absolute; script can run from anywhere
#
# Why this exists (260429-qyu post-mortem):
#   The wazuh-docker compose bind-mounts config/wazuh_dashboard/wazuh.yml
#   directly into the dashboard container. That single-file mount overrides
#   the wazuh-dashboard-config named volume, so the dashboard reads its API
#   credentials from the source-tree file — NOT from any env var. The
#   upstream wazuh.yml ships with the default `MyS3cr37P450r.*-` password
#   and is not templated by the entrypoint. Without this script, rotating
#   API_PASSWORD never reaches the dashboard.
#
#   Symptom: dashboard shows "Server API not connected" / "Server API down"
#   even though manager + indexer + TLS are all healthy.
#
# SOPS hardening (2026-05-23):
#   Earlier versions of this script read INDEXER_PASSWORD / API_PASSWORD from
#   a plaintext `.env` co-located with the compose stack on the CIFS NAS
#   mount (//__NAS-IP__/kub). The CIFS mount forces `file_mode=0755`, which
#   made `.env` world-readable to anyone with SMB access to the share — and
#   `chmod 600` was a no-op against the mount option. Two changes fixed this:
#     1. The plaintext was first moved to `/etc/wazuh/wazuh.env` on docker-1
#        local disk (root:root 0600, off CIFS).
#     2. That file was then SOPS-encrypted to `/etc/wazuh/wazuh.env.enc` and
#        the plaintext shredded. Plaintext now exists only transiently in
#        `/run/wazuh.env.XXXXXX` (tmpfs) during the lifetime of this script.
#
# PROVISIONING REQUIRED on a fresh docker-1 (one-time, out-of-band — not in git):
#   /etc/wazuh/age.key         age private key, root:root 0600
#   /etc/wazuh/wazuh.env.enc   SOPS-encrypted dotenv with INDEXER_PASSWORD + API_PASSWORD
#   /etc/wazuh/age.pub         age public recipient (informational)
#   Tools: age (apt) + sops (GitHub binary v3.9.4+)
#   Backup the age key off-device — if lost, the encrypted env is unrecoverable.
#
# Override knobs:
#   ENV_FILE_ENC          default /etc/wazuh/wazuh.env.enc
#   SOPS_AGE_KEY_FILE     default /etc/wazuh/age.key
#
# What this script does:
#   1. Decrypts ENV_FILE_ENC to /run (tmpfs) via sops, trap-shreds on exit
#   2. TRUNCATE-rewrites config/wazuh_dashboard/wazuh.yml so the dashboard
#      sees the rotated value on next start (CIFS-safe — preserves inode)
#   3. docker compose --env-file <decrypted> up -d (no-op if already up + matching env)
#   4. Re-applies API_PASSWORD to the manager's wazuh-wui user via
#      create_user.py (idempotent — updates if user exists, creates otherwise)

set -euo pipefail

cd /mnt/kub/homelab/wazuh/single-node

# --- SOPS-encrypted env: decrypt to /run (tmpfs) at start, shred on exit ---
ENV_FILE_ENC="${ENV_FILE_ENC:-/etc/wazuh/wazuh.env.enc}"
export SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-/etc/wazuh/age.key}"

if [[ ! -f "$ENV_FILE_ENC" ]]; then
  echo "ERROR: encrypted env not found at $ENV_FILE_ENC. See PROVISIONING block above." >&2
  exit 1
fi
if [[ ! -f "$SOPS_AGE_KEY_FILE" ]]; then
  echo "ERROR: age key not found at $SOPS_AGE_KEY_FILE. See PROVISIONING block above." >&2
  exit 1
fi
if ! command -v sops >/dev/null 2>&1; then
  echo "ERROR: sops binary not in PATH. Install from https://github.com/getsops/sops/releases" >&2
  exit 1
fi

ENV_FILE=$(mktemp --tmpdir=/run wazuh.env.XXXXXX)
chmod 600 "$ENV_FILE"
trap 'shred -u "$ENV_FILE" 2>/dev/null || rm -f "$ENV_FILE"' EXIT
sops --decrypt --input-type dotenv --output-type dotenv "$ENV_FILE_ENC" > "$ENV_FILE"

COMPOSE="docker compose --env-file $ENV_FILE"

INDEXER_PW=$(grep '^INDEXER_PASSWORD=' "$ENV_FILE" | cut -d= -f2-)
API_PW=$(grep '^API_PASSWORD=' "$ENV_FILE" | cut -d= -f2-)

if [[ -z "$INDEXER_PW" || -z "$API_PW" ]]; then
  echo "ERROR: INDEXER_PASSWORD or API_PASSWORD missing from decrypted env." >&2
  exit 1
fi

WAZUH_YML=config/wazuh_dashboard/wazuh.yml
if [[ ! -f "$WAZUH_YML" ]]; then
  echo "ERROR: $WAZUH_YML not found. Compose tree may be incomplete." >&2
  exit 1
fi

# Rewrite dashboard wazuh.yml from decrypted env. CRITICAL: must be a TRUNCATE
# in-place (preserves inode), NOT sed-with-rename. The compose bind-mounts
# this file's inode into the dashboard container; sed -i creates a new
# inode and renames it over the old, leaving the container's bind-mount
# pointing at a stale handle. On CIFS this manifests as "Stale file
# handle" errors and the dashboard fails to read its API config.
#
# Stop the dashboard before write so any cached file handle is released,
# then restart with `compose up -d` below.
$COMPOSE stop wazuh.dashboard >/dev/null 2>&1 || true

# Use python to dodge shell-quoting hell with $API_PW (which may contain
# special chars like `.`, `!`, `*`).
python3 - "$API_PW" "$WAZUH_YML" <<'PY_EOF'
import sys
api_pw, target = sys.argv[1], sys.argv[2]
content = (
    'hosts:\n'
    '  - 1513629884013:\n'
    '      url: "https://wazuh.manager"\n'
    '      port: 55000\n'
    '      username: wazuh-wui\n'
    f'      password: "{api_pw}"\n'
    '      run_as: true\n'
)
with open(target, 'w') as f:
    f.write(content)
PY_EOF
echo "[deploy] dashboard wazuh.yml rewritten in-place from decrypted env"

$COMPOSE up -d

# After stack-up, ensure manager's wazuh-wui API user matches API_PASSWORD.
# Required because the manager's first-boot init only runs against an empty
# user store; on subsequent restarts (or when the user was created with a
# different password earlier), the env var alone won't propagate.
if $COMPOSE ps --status running --quiet wazuh.manager >/dev/null 2>&1; then
  # Wait for the API user store to be writable (manager init can take a moment)
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if $COMPOSE exec -T wazuh.manager test -d /var/ossec/api/configuration; then
      break
    fi
    sleep 3
  done

  $COMPOSE exec -T wazuh.manager sh -c "cat > /var/ossec/api/configuration/admin.json <<EOF
{
  \"username\": \"wazuh-wui\",
  \"password\": \"$API_PW\"
}
EOF"
  if $COMPOSE exec -T wazuh.manager \
       /var/ossec/framework/python/bin/python3 \
       /var/ossec/framework/scripts/create_user.py; then
    echo "[deploy] manager wazuh-wui API user password synced to encrypted env"
  else
    echo "[deploy] WARNING: create_user.py exited non-zero — check manager logs" >&2
  fi
fi

echo "[deploy] done. Stack state:"
$COMPOSE ps
