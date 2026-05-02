# dock_nodes Terraform module

Proxmox VM provisioner for dock host clones (active/active mirror nodes for
docker-1's stateless workloads). Clones from `ubuntu-tmp` (vmid 107 on __PVE-NODE-1__).

Plan source-of-truth: [`/Volumes/code/homelab/docker-1/MIRROR-PLAN.md`](../../docker-1/MIRROR-PLAN.md).

## Status

- **docker-1 is NOT TF-managed** — predates this module, manually built. Don't
  try to import; Telmate's efidisk handling forces replacement on import.
- **docker-2 was provisioned 2026-05-02 via direct PVE API calls, NOT this
  module** — see "Reality check" below for why. The module captures the
  *intent* (sizing, networking, bootstrap script) but cannot run end-to-end
  against current cluster storage. Still useful as documentation + dry-run.
- This module is for **net-new dock nodes only** (docker-3, ...).

## Reality check — what bites you (learned the hard way on docker-2)

1. **PVE blocks cross-node clones on non-shared storage.** `ubuntu-tmp`
   lives on __PVE-NODE-1__'s `local-zfs`. With no shared+images storage in this
   cluster (`zfs1` is per-node despite `nodes=all`; `storage-synology` doesn't
   accept image content), `terraform apply` fails with `can't clone to
   non-shared storage 'zfs1'`. Workaround: clone in-node on __PVE-NODE-1__ first,
   then offline-migrate the resulting VM to the target node. Telmate
   provider 3.0.1-rc6 doesn't expose a clone-time storage redirect.
2. **The `ubuntu-tmp` template ignores PVE cloud-init.** ide2 is correctly
   attached and the ISO content (sshkeys/ipconfig0/ciuser) is correct, but
   the guest never applies it. SSH keys aren't authorized; netplan still
   runs DHCP. **Manual fix path**: SSH in as the template's hard-coded
   user (__NAS-USER__ / Tr00tr@sh), `sudo` to write a static netplan, append
   the operator pubkey to `bastion`'s `authorized_keys`, then proceed.
3. **`ubuntu-tmp` ships with `vcpus=2`** — a hot-plug cap. With sockets=1
   cores=8 vcpus=2, QEMU boots 2 online + 6 offline. Delete the vcpus
   key (PVE API: `delete=vcpus`) before stop+start.
4. **A guest reboot doesn't apply hot-add core changes** — the QEMU
   process needs a full PVE-level stop+start to pick up new cores.
   `systemctl reboot` is not enough.
5. **Telmate provider treats `target_node` change as a force-replace** —
   don't try to import the API-provisioned docker-2 into TF state and
   reconfigure it later; it'll plan a destroy+recreate.

## Pragmatic provisioning path (until ubuntu-tmp / shared storage are fixed)

Use direct PVE API calls. Sequence used for docker-2:

```text
1. POST .../qemu/107/clone   newid=N name=dockN full=1                   (in-node on __PVE-NODE-1__)
2. PUT  .../qemu/N/config    cores=... memory=... ipconfig0=... ciuser=bastion
                             sshkeys=<double-url-encoded> agent=enabled=1
3. PUT  .../qemu/N/resize    disk=scsi0 size=100G
4. POST .../qemu/N/migrate   target=pveX targetstorage=zfs1              (offline migrate)
5. PUT  .../qemu/N/config    delete=vcpus                                (let all cores boot)
6. PUT  .../qemu/N/config    ide2=zfs1:cloudinit                         (only if template lacks it)
7. POST .../qemu/N/status/start
8. <after boot> SSH as __NAS-USER__/Tr00tr@sh and:
     - install bastion pubkey to /home/bastion/.ssh/authorized_keys
     - write /etc/netplan/01-static.yaml with static IP (see "Manual netplan" below)
     - echo 'network: {config: disabled}' > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
     - netplan apply
9. ssh bastion@<new-ip> 'sudo bash -s' < cloud-init/bootstrap.sh
10. scp CIFS creds + Komodo .env from docker-1, install Periphery
```

Steps 8-9 are the manual hop forced by issue #2 above. Until ubuntu-tmp
is rebuilt with cloud-init properly enabled (or replaced with a template
that honors NoCloud), every dock node clone needs this.

## Add a node

```hcl
# in *.auto.tfvars (see docker-2.auto.tfvars.example)
nodes = {
  docker-2 = { target_node = "__PVE-NODE-3__", ip = "__LAN-IP__" }
}
```

Pick `target_node`:

```bash
# Source the PVE token (lives in /Volumes/code/projects/bastion/.env on this Mac)
set -a; . /Volumes/code/projects/bastion/.env; set +a
TID="${OPSMAN_PROXMOX__TOKEN_ID}"
TSEC="${OPSMAN_PROXMOX__TOKEN_SECRET}"

# List per-node running load and find docker-1's current host:
curl -ks -H "Authorization: PVEAPIToken=${TID}=${TSEC}" \
  "https://__PVE1-IP__:8006/api2/json/cluster/resources?type=vm" \
  | jq -r '.data | sort_by(.node) | (group_by(.node)[] | "\(.[0].node)\trunning_mem=\(([.[] | select(.status=="running") | .maxmem // 0] | add) / 1073741824 | floor)GiB")'
curl -ks -H "Authorization: PVEAPIToken=${TID}=${TSEC}" \
  "https://__PVE1-IP__:8006/api2/json/cluster/resources?type=vm" \
  | jq -r '.data[] | select(.name=="docker-1") | "docker-1 host: \(.node)"'
```

Pick the lightest host that is **not** docker-1's host. As of 2026-05-01, that is
`__PVE-NODE-3__` (__PVE-NODE-1__ has docker-1; __PVE-NODE-2__/__PVE-NODE-3__ tied on running load, __PVE-NODE-3__ has no
TF-managed resources so cleaner blast separation).

Default sizing per `variables.tf` (4 vCPU / 16 GiB / 100 GiB) matches the
mirror plan; override per-node only if a workload demands more.

## Bootstrap is post-apply, not cicustom

Earlier versions referenced `cicustom`. Dropped because PVE's API token only
permits iso/vztmpl/import uploads to storage — not snippets. Rather than
chase a per-PVE-node SSH workaround, the equivalent bootstrap (apt installs,
/etc/hosts NAS pin, fstab CIFS line, bastion docker group) runs as a
post-apply shell script over SSH. Idempotent and re-runnable.

```bash
# After terraform apply finishes and the new VM has SSH up:
ssh bastion@<new-ip> 'sudo bash -s' < cloud-init/bootstrap.sh
```

## Apply (will currently fail — see "Reality check")

```bash
cd terraform/dock_nodes
terraform init
terraform plan -out=docker-2.tfplan
terraform apply docker-2.tfplan
```

Expected failure on cross-node clone with current storage layout. Use the
"Pragmatic provisioning path" above instead.

## Manual netplan (Reality check #2 workaround)

Drop this at `/etc/netplan/01-dockN-static.yaml` (mode 0600):

```yaml
network:
  version: 2
  renderer: networkd
  ethernets:
    ens18:
      dhcp4: false
      dhcp6: false
      addresses:
        - <IP>/24
      routes:
        - to: default
          via: __LAN-IP__
      nameservers:
        addresses: [__PIHOLE1-IP__]
        search: [__BASE-DOMAIN__]
```

Then on the box (as root via PVE console or sudo'd from the template's
default user):

```bash
sudo install -m 0600 /dev/stdin /etc/netplan/01-dockN-static.yaml <<'EOF'
[paste yaml]
EOF
sudo mv /etc/netplan/50-cloud-init.yaml /etc/netplan/50-cloud-init.yaml.bak 2>/dev/null
echo 'network: {config: disabled}' | sudo tee /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
sudo netplan apply
```

Iface name is `ens18` on i440fx (match docker-1). If the image was built with
q35 it would be `enp1s0` / `enp6s18` — see `../k3s_nodes/README.md`'s iface
naming section.

## Post-clone runbook

Cloud-init covers package installs and the NAS DNS pin. The remaining steps
need secret material (CIFS credentials, Komodo passkey) and so live here, not
in cicustom.

### 1. Mount /mnt/kub

```bash
# From your workstation (or via bastion jump):
ssh bastion@<new-ip> 'sudo mkdir -p /mnt/kub'

# scp docker-1's CIFS creds (root-readable on docker-1 at /etc/samba/credentials):
ssh bastion@__LAN-IP__ 'sudo cat /etc/samba/credentials' \
  | ssh bastion@<new-ip> 'sudo tee /etc/samba/credentials > /dev/null && sudo chmod 0600 /etc/samba/credentials'

# Uncomment the fstab line cloud-init left commented:
ssh bastion@<new-ip> "sudo sed -i 's|^# //__NAS-IP__/kub|//__NAS-IP__/kub|' /etc/fstab && sudo systemctl daemon-reload && sudo mount -a && ls /mnt/kub"
# Expect: list of homelab dirs (cryptpad, maltrail, nextcloud, ...).
```

### 2. Install Komodo Periphery

docker-1 runs Komodo **Core** (the controller); each dock node runs **Periphery**
(the agent). Same passkey on Core and every Periphery — that's how Core
authenticates the agent.

```bash
# On the new dock node, as bastion:
sudo mkdir -p /opt/komodo
ssh bastion@__LAN-IP__ 'sudo cat /opt/komodo/.env' \
  | sudo tee /opt/komodo/.env > /dev/null
sudo chmod 0600 /opt/komodo/.env

sudo tee /opt/komodo/periphery-only.yaml > /dev/null <<'EOF'
services:
  periphery:
    image: ghcr.io/moghtech/komodo-periphery:latest
    restart: unless-stopped
    env_file: /opt/komodo/.env
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - /proc:/proc:ro
      - keys:/config/keys
volumes:
  keys: {}
EOF

sudo docker compose -f /opt/komodo/periphery-only.yaml up -d
```

Verify Periphery is listening:

```bash
ss -tlnp 2>/dev/null | grep 8120  # Periphery default
```

### 3. Register in Komodo Core UI

In Komodo at `http://__LAN-IP__:9120`:

1. **Servers → New** → name `<dockN>`, address `http://<new-ip>:8120`,
   passkey from the shared `.env` (`PERIPHERY_PASSKEYS`).
2. **Servers → \<dockN\> → Health** turns green within ~30s.

### 4. Reassign stateless stacks

In Komodo, edit each **stateless** stack (drawio is k8s-native and excluded;
legacy-vm is the main candidate as of 2026-05-01) → server list += new node.

Stateful singletons stay on docker-1 only:

- wazuh-stack
- qbittorrent + gluetun
- openvas
- maltrail
- cryptpad
- checkmk

### 5. Update Traefik EndpointSlices

For each stateless service the new node mirrors, edit the bundle in
`clusters/default/<svc>.yaml` to add a second `addresses` entry:

```yaml
endpoints:
  - addresses: [__LAN-IP__]    # docker-1
    conditions: { ready: true, serving: true, terminating: false }
  - addresses: [<new-ip>]      # dockN
    conditions: { ready: true, serving: true, terminating: false }
```

Commit + push; flux reconciles. Traefik round-robins by default — no service
config change needed.

### 6. Validate

```bash
# Round-robin check (run repeatedly; netdata per-host request rate should
# split between docker-1 and the new node):
for i in {1..10}; do curl -ksSL -o /dev/null -w "%{http_code}\n" https://legacy-vm.__BASE-DOMAIN__; done

# Failover check: pause docker-1's container; service stays up via new node.
ssh bastion@__LAN-IP__ 'sudo docker pause legacy-vm'
curl -ksSL -o /dev/null -w "during docker-1 pause: %{http_code}\n" https://legacy-vm.__BASE-DOMAIN__
ssh bastion@__LAN-IP__ 'sudo docker unpause legacy-vm'
```

## Provider note

`telmate/proxmox` 3.0.1-rc6 has known import issues (efidisk forces
replacement). Don't try to bring docker-1 under TF management. Future re-arch
would need a greenfield rebuild.

## What this module does NOT do

- Install k3s (this is for **docker hosts**, not k3s workers — see `../k3s_nodes/`)
- Ship CIFS credentials or Komodo passkey (secret; operator runbook above)
- Auto-pick `target_node` (operator runs the curl/jq snippet above)
- Update cluster manifests (`clusters/default/<svc>.yaml`) with the new
  EndpointSlice address — that's a separate flux change after the node is up
