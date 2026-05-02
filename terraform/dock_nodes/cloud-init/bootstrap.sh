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
#   - install Komodo Periphery → needs /opt/komodo/.env scp'd from docker-1 (secret)
#   - register the node in Komodo Core UI
#   - update Traefik EndpointSlices in clusters/default/{legacy-vm,...}.yaml

set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "ERROR: must run as root (sudo bash bootstrap.sh)." >&2
  exit 1
fi

echo "[1/6] apt update + install docker / cifs-utils / tools"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  docker.io \
  docker-compose-v2 \
  cifs-utils \
  curl \
  jq \
  ca-certificates

echo "[2/6] /etc/hosts pin for __NAS-HOST__ (idempotent)"
if ! grep -q "__NAS-IP__ __NAS-HOST__" /etc/hosts; then
  cat >> /etc/hosts <<'EOF'

# bootstrap.sh: NAS pin (see homelab access_paths memory)
__NAS-IP__ __NAS-HOST__ storage
EOF
fi

echo "[3/6] /etc/fstab CIFS line (commented; uncomment after scp'ing creds)"
if ! grep -q "//__NAS-IP__/kub" /etc/fstab; then
  cat >> /etc/fstab <<'EOF'

# bootstrap.sh: NAS CIFS mount (uncomment after scp'ing /etc/samba/credentials from docker-1)
# //__NAS-IP__/kub  /mnt/kub  cifs  credentials=/etc/samba/credentials,uid=1000,gid=1000,iocharset=utf8,vers=3.0  0  0
EOF
fi

echo "[4/6] mkdir /mnt/kub /var/lib/komodo-data"
mkdir -p /mnt/kub /var/lib/komodo-data

echo "[5/6] usermod bastion -aG docker"
if id -u bastion >/dev/null 2>&1; then
  usermod -aG docker bastion
else
  echo "WARN: bastion user not present yet — cloud-init may still be running. Re-run later."
fi

echo "[6/6] enable + start docker"
systemctl enable --now docker

echo
echo "==== bootstrap.sh complete ===="
echo "Next operator steps (see README.md \"Post-clone runbook\"):"
echo "  1. scp /etc/samba/credentials from docker-1, uncomment fstab CIFS line, mount -a"
echo "  2. scp /opt/komodo/.env from docker-1, install Komodo Periphery"
echo "  3. Register the node in Komodo Core UI"
echo "  4. Add new node IP to Traefik EndpointSlices in clusters/default/<svc>.yaml"
