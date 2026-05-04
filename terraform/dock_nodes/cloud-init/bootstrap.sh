#!/usr/bin/env bash
# dock node post-apply bootstrap — run this on a fresh dock<N> VM after
# `terraform apply` brings it up with cloud-init networking + bastion SSH.
#
# Why a script instead of cicustom: PVE's API token can only upload
# iso/vztmpl/import content to storage — not snippets. Distributing this as
# a cloud-init user-data file would require either root SSH on every PVE
# node or a NAS share already mounted on PVE with snippets content. Sidestep
# the whole problem by running it post-apply over SSH (idempotent, re-runnable).
#
# Usage (from a host that can SSH to the new dock node):
#   ssh bastion@<new-ip> 'sudo bash -s' < bootstrap.sh
#
# What this DOES configure:
#   - root filesystem grown to fill the entire disk (handles LVM and direct
#     partition layouts; idempotent — no-op when already grown)
#   - cloud-init network module disabled on subsequent boots so it doesn't
#     re-mutate netplan after first-boot setup
#   - qemu-guest-agent (installed here, not in the template, because
#     libguestfs's appliance VM has unreliable DNS for image-time apt installs)
#   - docker.io + docker compose v2 plugin (apt: docker-compose-v2)
#   - cifs-utils (required for the //__NAS-IP__/kub NAS mount that docker-1 uses)
#   - /etc/hosts override for __NAS-HOST__ → __NAS-IP__ (load-bearing per
#     the cluster's DNS topology — see access_paths memory; without this the
#     CIFS mount fails to resolve the NAS hostname after fresh-clone reboots)
#   - bastion → docker group (so bastion can run docker without sudo)
#   - empty /mnt/kub mountpoint dir
#   - /etc/fstab CIFS line (commented; uncomment after secret scp)
#
# What this does NOT do (separate steps in README "Post-clone runbook"):
#   - mount /mnt/kub  → needs /etc/samba/credentials scp'd from docker-1 (secret)
#   - configure Kopia → Wasabi backups → run cloud-init/kopia-backup.sh with
#     KOPIA_PASSWORD + Wasabi creds (secret env vars)
#   - install Komodo Periphery → needs /opt/komodo/.env scp'd from docker-1 (secret)
#   - register the node in Komodo Core UI
#   - update Traefik EndpointSlices in clusters/default/{legacy-vm,...}.yaml

set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "ERROR: must run as root (sudo bash bootstrap.sh)." >&2
  exit 1
fi

echo "[1/8] grow root filesystem to fill disk (idempotent)"
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

echo "[2/8] disable cloud-init network re-mutation on subsequent boots"
mkdir -p /etc/cloud/cloud.cfg.d
echo 'network: {config: disabled}' > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg

echo "[3/8] apt update + install qemu-guest-agent / docker / cifs-utils / tools"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  qemu-guest-agent \
  docker.io \
  docker-compose-v2 \
  cifs-utils \
  curl \
  jq \
  ca-certificates
# qemu-guest-agent.service has no [Install] section — it's udev-triggered when
# /dev/virtio-ports/org.qemu.guest_agent.0 appears. The terraform `agent = 1`
# flag creates that port; the service auto-starts. Don't `systemctl enable`.

echo "[4/8] /etc/hosts pin for __NAS-HOST__ (idempotent)"
if ! grep -q "__NAS-IP__ __NAS-HOST__" /etc/hosts; then
  cat >> /etc/hosts <<'EOF'

# bootstrap.sh: NAS pin (see homelab access_paths memory)
__NAS-IP__ __NAS-HOST__ storage
EOF
fi

echo "[5/8] /etc/fstab CIFS line (commented; uncomment after scp'ing creds)"
if ! grep -q "//__NAS-IP__/kub" /etc/fstab; then
  cat >> /etc/fstab <<'EOF'

# bootstrap.sh: NAS CIFS mount (uncomment after scp'ing /etc/samba/credentials from docker-1)
# //__NAS-IP__/kub  /mnt/kub  cifs  credentials=/etc/samba/credentials,uid=1000,gid=1000,iocharset=utf8,vers=3.0  0  0
EOF
fi

echo "[6/8] mkdir /mnt/kub /var/lib/komodo-data"
mkdir -p /mnt/kub /var/lib/komodo-data

echo "[7/8] usermod bastion -aG docker"
if id -u bastion >/dev/null 2>&1; then
  usermod -aG docker bastion
else
  echo "WARN: bastion user not present yet — cloud-init may still be running. Re-run later."
fi

echo "[8/8] enable + start docker"
systemctl enable --now docker

echo
echo "==== bootstrap.sh complete ===="
echo "Next operator steps (see README.md \"Post-clone runbook\"):"
echo "  1. scp /etc/samba/credentials from docker-1, uncomment fstab CIFS line, mount -a"
echo "  2. Run cloud-init/kopia-backup.sh with KOPIA_PASSWORD + Wasabi creds"
echo "  3. scp /opt/komodo/.env from docker-1, install Komodo Periphery"
echo "  4. Register the node in Komodo Core UI"
echo "  5. Add new node IP to Traefik EndpointSlices in clusters/default/<svc>.yaml"
