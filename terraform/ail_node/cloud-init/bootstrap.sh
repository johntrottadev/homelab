#!/usr/bin/env bash
# app-vm post-clone bootstrap. Runs once on a fresh ubuntu-24-tpl clone to
# prep the host for AIL Framework's installing_deps.sh. Lean: no docker,
# no NAS CIFS mount (AIL is single-node and stores everything locally; the
# off-site durability comes from Kopia → Wasabi via kopia-backup.sh).
#
# Usage (from a host that can SSH to the new VM):
#   ssh bastion@<new-ip> 'sudo bash -s' < bootstrap.sh
#
# What this DOES configure:
#   - root filesystem grown to fill the entire disk (idempotent)
#   - cloud-init network module disabled on subsequent boots
#   - qemu-guest-agent (installed here, not in the template)
#   - apt build deps that AIL's installing_deps.sh expects to find
#     (git, build-essential, libssl-dev, etc. — installer also self-installs
#     most of these but pre-staging them shortens its first run and avoids
#     interactive frontend prompts during app-vm-install.sh)
#   - qemu-guest-agent + jq + curl + ca-certificates
#   - operator dirs: /opt/app-vm (clone target), /var/lib/app-vm (data root)
#
# What this does NOT do (separate steps):
#   - clone + install AIL  → see cloud-init/app-vm-install.sh
#   - configure Kopia backups → re-use terraform/dock_nodes/cloud-init/kopia-backup.sh
#     with KOPIA_PATHS="/opt/app-vm/configs /var/lib/app-vm" and KOPIA_S3_PREFIX="vm/app-vm/"

set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "ERROR: must run as root (sudo bash bootstrap.sh)." >&2
  exit 1
fi

echo "[1/6] grow root filesystem to fill disk (idempotent)"
ROOT_SRC="$(findmnt -no SOURCE /)"
case "${ROOT_SRC}" in
  /dev/mapper/*|/dev/dm-*)
    PV_PART="$(pvs --noheadings -o pv_name 2>/dev/null | head -1 | tr -d ' ' || true)"
    if [[ -n "${PV_PART}" ]]; then
      PV_DISK="$(lsblk -no PKNAME "${PV_PART}" 2>/dev/null | head -1 || true)"
      PV_PNUM="$(echo "${PV_PART}" | grep -oE '[0-9]+$' || true)"
      if [[ -n "${PV_DISK}" && -n "${PV_PNUM}" ]]; then
        growpart "/dev/${PV_DISK}" "${PV_PNUM}" 2>/dev/null || true
        pvresize "${PV_PART}" 2>/dev/null || true
        lvextend -l +100%FREE "${ROOT_SRC}" 2>/dev/null || true
        resize2fs "${ROOT_SRC}" 2>/dev/null || true
      fi
    fi
    ;;
  /dev/sd*|/dev/vd*|/dev/nvme*)
    ROOT_DISK="$(lsblk -no PKNAME "${ROOT_SRC}" 2>/dev/null | head -1 || true)"
    ROOT_PNUM="$(echo "${ROOT_SRC}" | grep -oE '[0-9]+$' || true)"
    if [[ -n "${ROOT_DISK}" && -n "${ROOT_PNUM}" ]]; then
      growpart "/dev/${ROOT_DISK}" "${ROOT_PNUM}" 2>/dev/null || true
      resize2fs "${ROOT_SRC}" 2>/dev/null || true
    fi
    ;;
esac
df -h / | tail -1

echo "[2/6] disable cloud-init network re-mutation on subsequent boots"
mkdir -p /etc/cloud/cloud.cfg.d
echo 'network: {config: disabled}' > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg

echo "[3/6] force apt IPv4 + apt update"
# Same fix as dock_nodes — canonical mirror returns AAAA-only, blocks for
# ~75s per fetch on this network.
if [[ ! -f /etc/apt/apt.conf.d/99force-ipv4 ]]; then
  echo 'Acquire::ForceIPv4 "true";' > /etc/apt/apt.conf.d/99force-ipv4
fi
export DEBIAN_FRONTEND=noninteractive
apt-get update

echo "[4/6] install qemu-guest-agent + AIL build prereqs"
# AIL's installing_deps.sh apt-installs many of these itself, but pre-staging
# avoids interactive frontend prompts mid-install and shortens first run.
apt-get install -y --no-install-recommends \
  qemu-guest-agent \
  curl jq ca-certificates \
  git \
  build-essential \
  python3 python3-venv python3-pip python3-dev \
  cmake \
  pkg-config \
  libssl-dev libffi-dev \
  libsnappy-dev \
  libzbar0 libzbar-dev \
  libfuzzy-dev \
  libev-dev \
  libgmp-dev \
  protobuf-compiler \
  graphviz \
  p7zip-full \
  pgpdump \
  unzip wget rsync

echo "[5/6] mkdir AIL paths"
mkdir -p /opt/app-vm /var/lib/app-vm
# Owned by bastion so the AIL installer (run as bastion) can write them.
chown -R bastion:bastion /opt/app-vm /var/lib/app-vm

echo "[6/6] /etc/hosts pin for __NAS-HOST__ (idempotent)"
# Same DNS gotcha as dock_nodes: __NAS-HOST__ resolves to the Traefik VIP
# on internal DNS. app-vm doesn't currently mount NAS, but pin it anyway so
# any future rclone/scp to the NAS works without a Traefik round-trip.
if ! grep -q "__NAS-IP__ __NAS-HOST__" /etc/hosts; then
  cat >> /etc/hosts <<'EOF'

# bootstrap.sh: NAS pin (see homelab access_paths memory)
__NAS-IP__ __NAS-HOST__ storage
EOF
fi

echo
echo "==== bootstrap.sh complete ===="
echo "Next:"
echo "  1. ssh bastion@<this-ip> 'bash -s' < cloud-init/app-vm-install.sh"
echo "  2. Run kopia-backup.sh (re-use dock_nodes script) with"
echo "     KOPIA_PATHS=\"/opt/app-vm/configs /var/lib/app-vm\""
echo "     KOPIA_S3_PREFIX=\"vm/app-vm/\""
