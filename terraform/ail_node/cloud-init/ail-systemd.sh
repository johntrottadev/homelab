#!/usr/bin/env bash
# Install a systemd unit that auto-starts AIL on boot. AIL upstream uses
# LAUNCH.sh inside tmux for interactive runs; this wraps it as a oneshot
# unit so the host comes back online without manual intervention after a
# PVE migration / reboot / power loss.
#
# Idempotent — re-run to refresh.
#
#   ssh bastion@<app-vm-ip> 'sudo bash -s' < app-vm-systemd.sh
#
# Optional env overrides:
#   AIL_HOME    [/opt/app-vm]
#   AIL_USER    [bastion]   user that runs LAUNCH.sh (must own AIL_HOME)

set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "ERROR: must run as root (sudo bash app-vm-systemd.sh)." >&2
  exit 1
fi

AIL_HOME="${AIL_HOME:-/opt/app-vm}"
AIL_USER="${AIL_USER:-bastion}"

if [[ ! -x "${AIL_HOME}/bin/LAUNCH.sh" ]]; then
  echo "ERROR: ${AIL_HOME}/bin/LAUNCH.sh not found — run app-vm-install.sh first." >&2
  exit 1
fi

cat > /etc/systemd/system/app-vm.service <<EOF
[Unit]
Description=AIL Framework (Analysis Information Leak)
Documentation=https://github.com/app-vm-project/app-vm-framework
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
User=${AIL_USER}
WorkingDirectory=${AIL_HOME}/bin
# LAUNCH.sh -l starts Redis + KVRocks + workers + UI inside tmux.
# It's not a long-running foreground process, so Type=oneshot fits.
# RemainAfterExit=yes keeps the unit "active" so ExecStop can fire on shutdown.
ExecStart=/bin/bash ${AIL_HOME}/bin/LAUNCH.sh -l
ExecStop=/bin/bash ${AIL_HOME}/bin/LAUNCH.sh -k
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable app-vm.service
echo
echo "==== app-vm-systemd.sh complete ===="
echo "Unit:  /etc/systemd/system/app-vm.service (enabled)"
echo "Start: sudo systemctl start app-vm"
echo "Stop:  sudo systemctl stop app-vm"
echo "Logs:  journalctl -u app-vm -n 100 --no-pager"
