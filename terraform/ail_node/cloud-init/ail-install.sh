#!/usr/bin/env bash
# AIL Framework installer wrapper. Runs the upstream installing_deps.sh, then
# wires AIL to bind to all interfaces (default is 127.0.0.1) and configures
# the Lacus base URL so the crawler subsystem can reach
# http://__LAN-IP__:7100 (Lacus on docker-2).
#
# IMPORTANT: run as bastion, not root. AIL's installer expects to write into
# the user's HOME and creates a venv there. The installer does its own
# `sudo apt-get install` for any missing system deps.
#
#   ssh bastion@<app-vm-ip> 'bash -s' < app-vm-install.sh
#
# Idempotent — re-running pulls latest from main, re-runs installer (which
# is itself idempotent), and re-renders configs.
#
# Optional env overrides:
#   AIL_REPO_URL    [https://github.com/app-vm-project/app-vm-framework.git]
#   AIL_HOME        [/opt/app-vm]
#   AIL_BIND        [0.0.0.0]   web UI bind addr
#   LACUS_URL       [http://__LAN-IP__:7100]   AIL crawler → Lacus

set -euo pipefail

if [[ "${EUID}" -eq 0 ]]; then
  echo "ERROR: do NOT run as root. AIL's installer drops files into the user's HOME." >&2
  echo "Run as bastion:  ssh bastion@<ip> 'bash -s' < app-vm-install.sh" >&2
  exit 1
fi

AIL_REPO_URL="${AIL_REPO_URL:-https://github.com/app-vm-project/app-vm-framework.git}"
AIL_HOME="${AIL_HOME:-/opt/app-vm}"
AIL_BIND="${AIL_BIND:-0.0.0.0}"
LACUS_URL="${LACUS_URL:-http://__LAN-IP__:7100}"

echo "[1/5] clone or update AIL repo at ${AIL_HOME}"
if [[ ! -d "${AIL_HOME}/.git" ]]; then
  # bootstrap.sh chown'd /opt/app-vm to bastion, so this clone is non-root.
  git clone --recurse-submodules "${AIL_REPO_URL}" "${AIL_HOME}"
else
  cd "${AIL_HOME}"
  git pull --ff-only
  git submodule update --init --recursive
fi
cd "${AIL_HOME}"

echo "[2/5] run installing_deps.sh (will sudo for system pkgs)"
# The installer is interactive on apt prompts in some paths — set frontend.
export DEBIAN_FRONTEND=noninteractive
bash installing_deps.sh

echo "[3/5] render configs/core.cfg from sample (idempotent)"
if [[ ! -f configs/core.cfg ]]; then
  cp configs/core.cfg.sample configs/core.cfg
fi
# Bind the web UI to all interfaces so Traefik can reach it from the cluster.
# The sample ships host=127.0.0.1 — flip to ${AIL_BIND}.
sed -i "s|^host = 127.0.0.1$|host = ${AIL_BIND}|" configs/core.cfg

echo "[4/5] configure Lacus base URL"
# AIL's crawler reads Lacus URL from configs/core.cfg [Crawler] section.
# If [Crawler] block is absent (older sample), append it.
if grep -qE '^\[Crawler\]' configs/core.cfg; then
  # Replace existing lacus_url= line if present, else insert after the header.
  if grep -qE '^lacus_url\s*=' configs/core.cfg; then
    sed -i "s|^lacus_url\s*=.*|lacus_url = ${LACUS_URL}|" configs/core.cfg
  else
    sed -i "/^\[Crawler\]/a lacus_url = ${LACUS_URL}" configs/core.cfg
  fi
else
  cat >> configs/core.cfg <<EOF

[Crawler]
lacus_url = ${LACUS_URL}
EOF
fi

echo "[5/5] start AIL via LAUNCH.sh -l"
# LAUNCH.sh -l starts the full stack inside a tmux session named "Script"
# (Redis instances + KVRocks + workers + UI on :7000/HTTPS self-signed).
# Idempotent: -l first calls -k to stop anything running, then starts.
cd "${AIL_HOME}/bin"
./LAUNCH.sh -l

echo
echo "==== app-vm-install.sh complete ===="
echo
echo "Web UI:        https://$(hostname -I | awk '{print $1}'):7000  (self-signed)"
echo "Default user:  admin@admin.test"
echo "Default pass:  cat ${AIL_HOME}/DEFAULT_PASSWORD  (auto-deleted after first login)"
echo "Lacus URL:     ${LACUS_URL}  (configured in configs/core.cfg [Crawler])"
echo
echo "Behind Traefik (after wiring clusters/default/app-vm.yaml):"
echo "  https://app-vm.__BASE-DOMAIN__"
echo
echo "Stop / restart:    cd ${AIL_HOME}/bin && ./LAUNCH.sh -k && ./LAUNCH.sh -l"
echo "Tmux attach:       tmux attach -t Script"
