# app-vm-node Terraform module

Proxmox VM provisioner for the AIL Framework single-node host. Clones from
`ubuntu-24-tpl` (vmid 9000/9001/9002 — exists on every PVE node).

## Why a dedicated VM (not docker / not k3s)

The [AIL Framework](https://github.com/app-vm-project/app-vm-framework) ships
**zero container artifacts** — no Dockerfile, no compose, no helm. The
upstream `installing_deps.sh` targets Debian/Ubuntu and compiles Redis +
KVRocks + yara + tlsh from source. Re-implementing that as a container
stack would mean owning a custom Dockerfile against a moving target.

Lacus, the capture system AIL talks to over HTTP, ships a working upstream
docker-compose. It runs on docker-2 — see `docker-2/lacus/compose.yaml`.

## Sizing

Default — 4 vCPU / 8 GiB RAM / 60 GiB disk. Researcher reports a ~4-6 GiB
working set (5 Redis instances + KVRocks + Python workers); 8 GiB has
headroom for the UI and feed processing without swap pressure. Disk grows
with the paste corpus — watch `/var/lib/app-vm/PASTES` and bump `disk_size`
in tfvars if you onboard a high-volume feeder.

## Status

- **app-vm provisioned 2026-05-04 via direct `pvesh` over SSH on __PVE-NODE-1__.**
  The terraform module here is the canonical IaC record but was not used
  to apply: the `bastion@pve!read` token referenced by the dock_nodes
  module no longer exists (rotated to `bastion-audit@pve!read` /
  `bastion-write@pve!write`), and the secret in `~/projects/bastion/.env`
  was stale at provision time. Same precedent as docker-2 (provisioned via
  direct PVE API calls 2026-05-02). Don't try to `terraform import` —
  Telmate's efidisk handling forces replacement.

## Add a node

```hcl
# in *.auto.tfvars (see app-vm.auto.tfvars.example)
nodes = {
  app-vm = { target_node = "__PVE-NODE-2__", ip = "__LAN-IP__" }
}
```

Pick `target_node`: lightest-loaded host that is **not** already a docker
host (__PVE-NODE-1__ → docker-1, __PVE-NODE-3__ → docker-2). __PVE-NODE-2__ is the diversification choice
for blast separation across all three PVE nodes.

## Bootstrap is post-apply, not cicustom

Same constraint as dock_nodes: PVE's API token can't upload to snippets,
so bootstrap runs as post-apply SSH. AIL's installer + systemd unit
follow the same shape:

```bash
ssh bastion@<new-ip> 'sudo bash -s' < cloud-init/bootstrap.sh
ssh bastion@<new-ip> 'bash -s' < cloud-init/app-vm-install.sh        # NOT sudo — runs as bastion
ssh bastion@<new-ip> 'sudo bash -s' < cloud-init/app-vm-systemd.sh
```

`bootstrap.sh` is lean — no docker, no NAS CIFS mount, no Komodo
Periphery. AIL is a single-node stack and durability comes from Kopia
→ Wasabi.

## Apply (when token rotation is sorted)

```bash
cd terraform/app-vm-node
terraform init
terraform plan -out=app-vm.tfplan
terraform apply app-vm.tfplan
# Telmate provider creates the VM stopped. Start via PVE API or CLI.
```

## Post-clone runbook

### 1. Bootstrap host

```bash
ssh bastion@__LAN-IP__ 'sudo bash -s' < cloud-init/bootstrap.sh
```

Grows root fs, installs qemu-guest-agent, AIL build prereqs,
qemu-guest-agent. Idempotent.

### 2. Install AIL

```bash
ssh bastion@__LAN-IP__ 'bash -s' < cloud-init/app-vm-install.sh
```

Clones AIL upstream into `/opt/app-vm`, runs `installing_deps.sh`, renders
`configs/core.cfg` (binds web UI to 0.0.0.0, points crawler at
`http://__LAN-IP__:7100` for Lacus on docker-2), starts via `LAUNCH.sh -l`.

First run takes ~15-30 min (Redis + KVRocks compile from source).

After completion, capture the default admin password — it's printed in the
script output and also lives at `/opt/app-vm/DEFAULT_PASSWORD` until first
login.

### 3. Install systemd unit

```bash
ssh bastion@__LAN-IP__ 'sudo bash -s' < cloud-init/app-vm-systemd.sh
```

Wraps `LAUNCH.sh -l` in `app-vm.service` so AIL survives reboots.

### 4. Configure Kopia → Wasabi backups

Re-use the dock_nodes kopia-backup.sh with AIL-specific paths and prefix:

```bash
KOPIA_PASSWORD='<from password manager>'
KOPIA_SERVER_PASSWORD='<from password manager>'
read -r KOPIA_S3_ACCESS_KEY KOPIA_S3_SECRET_KEY < <(
  kubectl get secret velero-wasabi-creds -n velero -o jsonpath='{.data.cloud}' \
    | base64 -d \
    | awk -F= '/aws_access_key_id/{a=$2} /aws_secret_access_key/{s=$2} END{print a, s}'
)

ssh bastion@__LAN-IP__ \
  "export KOPIA_PASSWORD='$KOPIA_PASSWORD'; \
   export KOPIA_SERVER_PASSWORD='$KOPIA_SERVER_PASSWORD'; \
   export KOPIA_S3_ACCESS_KEY='$KOPIA_S3_ACCESS_KEY'; \
   export KOPIA_S3_SECRET_KEY='$KOPIA_S3_SECRET_KEY'; \
   export KOPIA_S3_PREFIX='vm/app-vm/'; \
   export KOPIA_PATHS='/opt/app-vm/configs /opt/app-vm/PASTES /opt/app-vm/DATA_KVROCKS'; \
   sudo --preserve-env=KOPIA_PASSWORD,KOPIA_SERVER_PASSWORD,KOPIA_S3_ACCESS_KEY,KOPIA_S3_SECRET_KEY,KOPIA_S3_PREFIX,KOPIA_PATHS bash -s" \
  < ../dock_nodes/cloud-init/kopia-backup.sh
```

This gives app-vm:
- A separate Kopia repo at `s3://__WASABI-BUCKET__/vm/app-vm/` (separate prefix
  from `dock/dockN/` so retention tunes independently).
- `prometheus-node-exporter` on `:9100` with the kopia textfile-collector
  metrics — picked up by the prometheus `dock-hosts` scrape job after
  app-vm is added there (see `clusters/default/monitoring/kube-prometheus-stack/helmrelease.yaml`).
- Read-only Kopia web UI on `:51515` — exposed via Traefik at
  `https://kopia-app-vm.__BASE-DOMAIN__` (see `clusters/default/kopia-app-vm.yaml`).

### 5. Wire Traefik route

`clusters/default/app-vm.yaml` is a Service+EndpointSlice+IngressRoute bundle
that fronts AIL on `https://app-vm.__BASE-DOMAIN__`. Upstream is HTTPS (AIL ships
self-signed) so the bundle uses `lan-self-signed` ServersTransport. Same
file pattern as `openvas.yaml`.

### 6. First login + admin password rotation

```bash
ssh bastion@__LAN-IP__ 'cat /opt/app-vm/DEFAULT_PASSWORD'
# Browse to https://app-vm.__BASE-DOMAIN__  → login as admin@admin.test / <printed>
# UI prompts for password change on first login; the file self-deletes.
```

### 7. Operator follow-ups (UI-only, not in this repo)

These bits live in app-managed state (SQLite or app DB), not in this git
repo. Add them once after the VM is up:

- **uptime-kuma** at `https://uptime.__BASE-DOMAIN__` → Add new HTTP(S) monitors:
  - `https://app-vm.__BASE-DOMAIN__/` (expect 302; tag `security`, `vm`)
  - `https://lacus.__BASE-DOMAIN__/` (expect 200; tag `security`, `docker-2`)
  - `https://kopia-app-vm.__BASE-DOMAIN__/` (expect 401; tag `backups`)
- **CheckMK** at `https://checkmk.__BASE-DOMAIN__` → Add `app-vm` (__LAN-IP__)
  as a new host using the same template as docker-1/docker-2. Run service
  discovery; activate.
- **Komodo** at `https://komodo.__BASE-DOMAIN__` — does NOT need to know about
  app-vm (Komodo only manages docker hosts; AIL is bare-metal).

## Provider note

Same caveat as dock_nodes — `telmate/proxmox` 3.0.1-rc6 has known import
issues. Don't try to bring app-vm under TF management after creation.
Future re-arch would need a greenfield rebuild.
