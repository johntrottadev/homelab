# dock_nodes Terraform module

Proxmox VM provisioner for dock host clones (active/active mirror nodes for
docker-1's stateless workloads). Clones from `ubuntu-tmp` (vmid 107 on __PVE-NODE-1__).

Plan source-of-truth: [`/Volumes/code/homelab/docker-1/MIRROR-PLAN.md`](../../docker-1/MIRROR-PLAN.md).

## Status

- **docker-1 is NOT TF-managed** — predates this module, manually built. Don't
  try to import; Telmate's efidisk handling forces replacement on import.
- This module is for **net-new dock nodes only** (docker-2, docker-3, ...).

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

## One-time per PVE node: deploy cloud-init snippet

Cross-node clones in Proxmox apply `cicustom` from the **target node's**
local snippets storage. Copy to each pve node ahead of any apply that may
target it:

```bash
for h in __PVE-NODE-1__ __PVE-NODE-2__ __PVE-NODE-3__; do
  scp cloud-init/dock-node-user-data.yaml root@$h:/var/lib/vz/snippets/
done
```

Without the snippet present, the clone boots fine but cloud-init logs an
error and the node lacks docker / cifs-utils / the NAS hosts override.

## Apply

```bash
cd terraform/dock_nodes
terraform init
terraform plan -out=docker-2.tfplan
terraform apply docker-2.tfplan
```

Terraform creates the VM stopped, then writes cloud-init config, then starts
it. Boot-to-SSH-ready is ~90s (template-dependent).

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
