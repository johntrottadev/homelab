#!/usr/bin/env bash
# k3s node post-apply bootstrap — run this on a fresh kub<N> VM after
# `terraform apply` brings it up with cloud-init networking + bastion SSH.
#
# Why a script instead of cicustom: PVE's API token can only upload
# iso/vztmpl/import content to storage — not snippets. Distributing this as
# a cloud-init user-data file would require either root SSH on every PVE
# node or a NAS share already mounted on PVE with snippets content. Sidestep
# the whole problem by running it post-apply over SSH (idempotent, re-runnable).
#
# Usage (from a host that can SSH to the new node):
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
#   - open-iscsi + iscsid enabled, and a multipathd blacklist for Longhorn —
#     baked in now so the later Longhorn phase needs no per-node retrofit
#     (harmless on nodes that never run Longhorn).
#   - k8s node sysctl tuning: raised fs.inotify limits. The distro default
#     (max_user_instances=128) is exhausted at high pod density and makes
#     file-watching pods crash with SIGSEGV / "inotify instance limit reached".
#     Discovered 2026-07-01 when consolidating the cluster onto 2 nodes during
#     the blue/green rebuild took jellyfin down.
#
# What this does NOT do (operator step after bootstrap):
#   - install k3s. This script is cluster-agnostic; the k3s install differs by
#     role and by whether you're joining an existing cluster or initializing a
#     new one:
#       * NEW cluster, FIRST server (inits etcd):
#           curl -sfL https://get.k3s.io | sh -s - server --cluster-init \
#             --disable servicelb
#       * NEW cluster, ADDITIONAL servers (join etcd quorum):
#           curl -sfL https://get.k3s.io | K3S_TOKEN=<server-token> sh -s - \
#             server --server https://<first-server>:6443 --disable servicelb
#       * agent:
#           curl -sfL https://get.k3s.io | K3S_URL=https://<server-or-vip>:6443 \
#             K3S_TOKEN=<agent-token> sh -s - agent
#     (tokens: /var/lib/rancher/k3s/server/{token,agent-token} on any server.
#      audit logging config.yaml is delivered separately, see homelab repo.)

set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "ERROR: must run as root (sudo bash bootstrap.sh)." >&2
  exit 1
fi

echo "[1/6] grow root filesystem to fill disk (idempotent)"
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

echo "[2/6] disable cloud-init network re-mutation on subsequent boots"
mkdir -p /etc/cloud/cloud.cfg.d
echo 'network: {config: disabled}' > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg

echo "[3/6] apt update + install qemu-guest-agent / nfs-common / open-iscsi"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  qemu-guest-agent \
  nfs-common \
  open-iscsi \
  curl \
  ca-certificates
# qemu-guest-agent.service has no [Install] section — it's udev-triggered when
# /dev/virtio-ports/org.qemu.guest_agent.0 appears. The terraform `agent = 1`
# flag creates that port; the service auto-starts. Don't `systemctl enable`.

echo "[4/6] Longhorn prerequisites — open-iscsi + multipath blacklist (idempotent)"
# Longhorn attaches volumes as iSCSI block devices; iscsid must be running.
systemctl enable --now iscsid
# multipathd (when present) claims Longhorn's device-mapper devices and breaks
# volume attach ("device already mounted"). Blacklist sd* so it ignores them.
# These VMs use virtio-scsi with no real multipath/SAN, so this is safe.
if systemctl list-unit-files 2>/dev/null | grep -q '^multipathd.service'; then
  mkdir -p /etc/multipath/conf.d
  cat > /etc/multipath/conf.d/longhorn.conf <<'MPEOF'
blacklist {
    devnode "^sd[a-z0-9]+"
}
MPEOF
  systemctl restart multipathd 2>/dev/null || true
fi

echo "[5/6] kubernetes node sysctl tuning (inotify limits)"
# Distro default fs.inotify.max_user_instances=128 is exhausted at high pod
# density; file-watching pods then crash with SIGSEGV / IOException. Raise it.
cat > /etc/sysctl.d/99-k8s-node.conf <<'SYSEOF'
fs.inotify.max_user_instances = 8192
fs.inotify.max_user_watches = 524288
SYSEOF
sysctl --system >/dev/null 2>&1 || true

echo "[6/6] bootstrap complete"

echo
echo "==== bootstrap.sh complete ===="
echo "Next operator step: install k3s (see the header comment for the"
echo "role-specific server/agent commands — a NEW cluster uses --cluster-init"
echo "on the first server, then joins the other two servers, then the agents)."
