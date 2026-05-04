#!/usr/bin/env bash
# k3s worker post-apply bootstrap — run this on a fresh kub<N> VM after
# `terraform apply` brings it up with cloud-init networking + bastion SSH.
#
# Why a script instead of cicustom: PVE's API token can only upload
# iso/vztmpl/import content to storage — not snippets. Distributing this as
# a cloud-init user-data file would require either root SSH on every PVE
# node or a NAS share already mounted on PVE with snippets content. Sidestep
# the whole problem by running it post-apply over SSH (idempotent, re-runnable).
#
# Usage (from a host that can SSH to the new worker):
#   ssh bastion@<new-ip> 'sudo bash -s' < bootstrap.sh
#
# What this DOES configure:
#   - root filesystem grown to fill the entire disk (handles LVM and direct
#     partition layouts; idempotent — no-op when already grown)
#   - cloud-init network module disabled on subsequent boots so it doesn't
#     re-mutate netplan after first-boot setup
#   - qemu-guest-agent (installed here, not in the template, because
#     libguestfs's appliance VM has unreliable DNS for image-time apt installs)
#   - nfs-common (required for NFS-backed PVCs; without it pods with NFS
#     volumes hang in ContainerCreating with "mount.nfs helper missing".
#     Discovered on k3s-7 post-rebuild 2026-04-27.)
#
# What this does NOT do (operator step after bootstrap):
#   - install k3s. Run on the new worker after this script:
#       curl -sfL https://get.k3s.io | K3S_URL=https://__K3S-API-IP__:6443 \
#         K3S_TOKEN=<server-token> sh -s - agent
#     (server-token comes from /var/lib/rancher/k3s/server/node-token on k3s-1)

set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "ERROR: must run as root (sudo bash bootstrap.sh)." >&2
  exit 1
fi

echo "[1/4] grow root filesystem to fill disk (idempotent)"
ROOT_SRC="$(findmnt -no SOURCE /)"
case "${ROOT_SRC}" in
  /dev/mapper/*|/dev/dm-*)
    # LVM root: grow PV partition → PV → LV → fs
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
    # Direct-partition root: grow partition + fs
    ROOT_DISK="$(lsblk -no PKNAME "${ROOT_SRC}" 2>/dev/null | head -1 || true)"
    ROOT_PNUM="$(echo "${ROOT_SRC}" | grep -oE '[0-9]+$' || true)"
    if [[ -n "${ROOT_DISK}" && -n "${ROOT_PNUM}" ]]; then
      growpart "/dev/${ROOT_DISK}" "${ROOT_PNUM}" 2>/dev/null || true
      resize2fs "${ROOT_SRC}" 2>/dev/null || true
    fi
    ;;
esac
df -h / | tail -1

echo "[2/4] disable cloud-init network re-mutation on subsequent boots"
mkdir -p /etc/cloud/cloud.cfg.d
echo 'network: {config: disabled}' > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg

echo "[3/4] apt update + install qemu-guest-agent / nfs-common"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  qemu-guest-agent \
  nfs-common \
  curl \
  ca-certificates
# qemu-guest-agent.service has no [Install] section — it's udev-triggered when
# /dev/virtio-ports/org.qemu.guest_agent.0 appears. The terraform `agent = 1`
# flag creates that port; the service auto-starts. Don't `systemctl enable`.

echo "[4/4] bootstrap complete"

echo
echo "==== bootstrap.sh complete ===="
echo "Next operator steps (see README.md \"Post-clone runbook\"):"
echo "  1. Grab the server node-token from k3s-1:"
echo "       ssh bastion@__K3S-API-IP__ 'sudo cat /var/lib/rancher/k3s/server/node-token'"
echo "  2. Install k3s agent on this node:"
echo "       curl -sfL https://get.k3s.io | K3S_URL=https://__K3S-API-IP__:6443 \\"
echo "         K3S_TOKEN=<token> sh -s - agent"
echo "  3. Verify from k3s-1: kubectl get nodes"
