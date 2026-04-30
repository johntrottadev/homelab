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
#   API_PASSWORD in .env never reaches the dashboard.
#
#   Symptom: dashboard shows "Server API not connected" / "Server API down"
#   even though manager + indexer + TLS are all healthy.
#
# What this script does:
#   1. Reads INDEXER_PASSWORD and API_PASSWORD from .env
#   2. TRUNCATE-rewrites config/wazuh_dashboard/wazuh.yml so the dashboard
#      sees the rotated value on next start (CIFS-safe — preserves inode)
#   3. docker compose up -d (no-op if already up + matching env)
#   4. Re-applies API_PASSWORD to the manager's wazuh-wui user via
#      create_user.py (idempotent — updates if user exists, creates otherwise)

set -euo pipefail

cd /mnt/kub/homelab/wazuh/single-node

if [[ ! -f .env ]]; then
  echo "ERROR: .env not found in /mnt/kub/homelab/wazuh/single-node. Expected INDEXER_PASSWORD and API_PASSWORD." >&2
  exit 1
fi

INDEXER_PW=$(grep '^INDEXER_PASSWORD=' .env | cut -d= -f2-)
API_PW=$(grep '^API_PASSWORD=' .env | cut -d= -f2-)

if [[ -z "$INDEXER_PW" || -z "$API_PW" ]]; then
  echo "ERROR: INDEXER_PASSWORD or API_PASSWORD missing from .env." >&2
  exit 1
fi

WAZUH_YML=config/wazuh_dashboard/wazuh.yml
if [[ ! -f "$WAZUH_YML" ]]; then
  echo "ERROR: $WAZUH_YML not found. Compose tree may be incomplete." >&2
  exit 1
fi

# Rewrite dashboard wazuh.yml from .env. CRITICAL: must be a TRUNCATE
# in-place (preserves inode), NOT sed-with-rename. The compose bind-mounts
# this file's inode into the dashboard container; sed -i creates a new
# inode and renames it over the old, leaving the container's bind-mount
# pointing at a stale handle. On CIFS this manifests as "Stale file
# handle" errors and the dashboard fails to read its API config —
# symptom: dashboard logs spam `UNKNOWN: unknown error, open` for
# wazuh.yml and the UI shows "Server API not connected" indefinitely.
#
# Stop the dashboard before write so any cached file handle is released,
# then restart with `compose up -d` below.
docker compose stop wazuh.dashboard >/dev/null 2>&1 || true

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
echo "[deploy] dashboard wazuh.yml rewritten in-place from .env"

docker compose up -d

# After stack-up, ensure manager's wazuh-wui API user matches API_PASSWORD.
# Required because the manager's first-boot init only runs against an empty
# user store; on subsequent restarts (or when the user was created with a
# different password earlier), the env var alone won't propagate.
if docker compose ps --status running --quiet wazuh.manager >/dev/null 2>&1; then
  # Wait for the API user store to be writable (manager init can take a moment)
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if docker compose exec -T wazuh.manager test -d /var/ossec/api/configuration; then
      break
    fi
    sleep 3
  done

  docker compose exec -T wazuh.manager sh -c "cat > /var/ossec/api/configuration/admin.json <<EOF
{
  \"username\": \"wazuh-wui\",
  \"password\": \"$API_PW\"
}
EOF"
  if docker compose exec -T wazuh.manager \
       /var/ossec/framework/python/bin/python3 \
       /var/ossec/framework/scripts/create_user.py; then
    echo "[deploy] manager wazuh-wui API user password synced to .env"
  else
    echo "[deploy] WARNING: create_user.py exited non-zero — check manager logs" >&2
  fi
fi

echo "[deploy] done. Stack state:"
docker compose ps
