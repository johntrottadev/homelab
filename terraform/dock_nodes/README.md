# dock_nodes Terraform module

Proxmox VM provisioner for dock host clones (active/active mirror nodes for
docker-1's stateless workloads). Clones from `ubuntu-24-tpl` (vmid 9000),
which exists on every PVE node so the clone is in-node regardless of
`target_node`.

Plan source-of-truth: [`/Volumes/code/homelab/docker-1/MIRROR-PLAN.md`](../../docker-1/MIRROR-PLAN.md).

## Status

- **docker-1 is NOT TF-managed** — predates this module, manually built. Don't
  try to import; Telmate's efidisk handling forces replacement on import.
- **docker-2 was provisioned 2026-05-02 via direct PVE API calls** under the
  old `ubuntu-tmp` template (which ignored cloud-init). It is not in TF
  state — don't try to import it (see provider note at the end).
- This module is for **net-new dock nodes only** (docker-3, ...).

## What used to bite (resolved by ubuntu-24-tpl)

The prior `ubuntu-tmp` (vmid 107) had a stack of papercuts that forced
direct-API provisioning. They no longer apply with `ubuntu-24-tpl`:

| Old pain | Fix |
|---|---|
| Cross-node clone blocked by non-shared storage | Template now exists on every PVE node — in-node clone always works |
| Template ignored PVE cloud-init (no SSH keys, DHCP netplan) | New template is canonical Ubuntu 24.04 cloud image; cloud-init applies normally |
| `vcpus=2` hot-plug cap forced manual `delete=vcpus` | New template has no vcpus key |
| LVM never grown, docker-2 came up with 28G of a 100G disk | `bootstrap.sh` step 1 grows root fs to fill the disk (handles LVM and direct-partition) |
| Cloud-init re-mutated netplan/DNS on subsequent boots | `bootstrap.sh` step 2 drops `99-disable-network-config.cfg` after first-boot |

**Still true:** Telmate provider treats `target_node` change as
force-replace — don't try to import a node and reassign hosts later;
it'll plan destroy+recreate.

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

PVE's API token only permits iso/vztmpl/import uploads to storage — not
snippets — so the bootstrap (disk grow, cloud-init network lockdown, apt
installs, /etc/hosts NAS pin, fstab CIFS line, bastion docker group) runs
as a post-apply shell script over SSH. Idempotent and re-runnable.

```bash
# After terraform apply finishes and the new VM has SSH up:
ssh bastion@<new-ip> 'sudo bash -s' < cloud-init/bootstrap.sh
```

## Apply

```bash
cd terraform/dock_nodes
terraform init
terraform plan -out=dockN.tfplan
terraform apply dockN.tfplan
# Telmate provider creates the VM stopped. Start it via PVE API:
#   curl -ks -H "Authorization: PVEAPIToken=${TID}=${TSEC}" \
#     -X POST "https://__PVE1-IP__:8006/api2/json/nodes/<pve-node>/qemu/<vmid>/status/start"
# Then over SSH:
ssh bastion@<new-ip> 'sudo bash -s' < cloud-init/bootstrap.sh
```

## BIOS + iface naming notes

- **`bios = "seabios"`** is required for the canonical Ubuntu cloud image.
  The image has a single ext4 partition on GPT, no EFI System Partition;
  OVMF lands in the firmware shell. Don't switch back to ovmf without
  rebuilding the template from a UEFI-capable source.
- **Iface comes up as `eth0`**, not `ens18`. Cloud-init's NoCloud
  network-config v1 (what PVE generates from `ipconfig0`) includes an
  implicit `set-name: eth0` directive that renames whatever the underlying
  predictable name is. After `bootstrap.sh` disables cloud-init network
  management on subsequent boots, the existing `/etc/netplan/50-cloud-init.yaml`
  keeps eth0 stable. docker-1/docker-2 are still `ens18` (predate this template);
  the fleet is heterogeneous but functional. Don't hard-code iface names
  in any config that needs to bind to a specific interface.

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
