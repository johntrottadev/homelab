# Replicating This Homelab

This guide walks you from "I just forked this repo" to "my homelab is reconciling on my
domain." It follows the PVE-canonical path (3-node Proxmox cluster, Synology NAS, k3s
via Ansible) and adds **Adapting for your stack** sidebars at each major swap-in point
so operators on different infrastructure can follow along. See [INFRASTRUCTURE.md](INFRASTRUCTURE.md)
for topology context.

---

## Prerequisites

### Tools

Install these before starting. Linux and macOS are assumed; Windows users should use WSL2.

| Tool | Min Version | Install |
|------|-------------|---------|
| `git` | 2.x | `brew install git` / OS package manager |
| `gh` | 2.x | `brew install gh` / [cli.github.com](https://cli.github.com) |
| `tofu` | >= 1.6 | `brew install opentofu` / [opentofu.org/docs/intro/install](https://opentofu.org/docs/intro/install/) |
| `ansible` | >= 2.15 | `pip install ansible` / `brew install ansible` |
| `kubectl` | >= 1.28 | `brew install kubectl` / [kubernetes.io/docs/tasks/tools](https://kubernetes.io/docs/tasks/tools/) |
| `flux` | 2.x | `brew install fluxcd/tap/flux` / [fluxcd.io/flux/installation](https://fluxcd.io/flux/installation/) |
| `kustomize` | 5.x | `brew install kustomize` / [kubectl.docs.kubernetes.io/installation/kustomize](https://kubectl.docs.kubernetes.io/installation/kustomize/) |

### Accounts

| Account | Purpose |
|---------|---------|
| GitHub | GitOps source; Flux watches your fork |
| Cloudflare (or other DNS provider) | ACME DNS-01 challenge for cert-manager Let's Encrypt certificates |
| Wasabi (or other S3-compatible provider) | Off-site backup target for Velero (k8s) and NAS Hyper Backup |

### Hardware

| Component | Purpose |
|-----------|---------|
| Proxmox VE cluster (3 nodes recommended) | VM host for k3s nodes and supporting VMs |
| NAS with NFS exports | Persistent storage for k8s PVCs; backup staging |
| Domain name | All IngressRoutes and TLS certificates derive from `BASE_DOMAIN` |
| S3-compatible storage | Off-site backup target (Wasabi is the tested provider) |

> This guide assumes Proxmox. See **Adapting for your stack** sidebars below for
> substitution points if you use a different hypervisor or bare metal.

---

## Step 1: Fork and Configure

### 1.1 Fork and Clone

Fork this repo via the GitHub UI or the `gh` CLI, then clone your fork locally:

```bash
# Fork via GitHub UI and then clone, OR use the gh CLI:
gh repo fork <OWNER>/homelab --clone --remote
cd homelab
```

Replace `<OWNER>` with the GitHub username of the upstream repo you are forking from.

### 1.2 Fill in .env

The `.env` file at the repo root is the local-developer interface for scripts that need
site-specific values. It is gitignored; the committed example file shows the required keys.

```bash
cp .env.example .env
# Edit .env — fill in all 21 variables (see table in 1.3 below)
```

### 1.3 Prepare cluster-vars

`flux-system/cluster-vars.example.yaml` is the committed template for the Kubernetes
ConfigMap consumed by Flux's `postBuild.substituteFrom`. The real copy must live
**off-tree** (gitignored) and be applied manually before Flux can reconcile.

```bash
# Copy the example to a path outside the repo (gitignored by design)
cp flux-system/cluster-vars.example.yaml /path/outside/repo/cluster-vars.yaml

# Edit the off-tree copy — fill in real values for all 21 keys
# (same key set as .env — they stay in sync)
```

#### cluster-vars Key Reference

Walk through each key before applying. Every key maps to a Flux substitution token used
across `clusters/default/` manifests.

| Variable | Purpose | Notes |
|----------|---------|-------|
| `BASE_DOMAIN` | Your domain; all IngressRoutes derive from this | e.g. `yourdomain.example` |
| `ACME_EMAIL` | Let's Encrypt ACME account email | Used by cert-manager ClusterIssuer |
| `S3_BUCKET` | Wasabi/S3 bucket name | Velero + NAS Hyper Backup target |
| `S3_ENDPOINT` | S3-compatible endpoint URL | e.g. `__WASABI-ENDPOINT__` |
| `S3_REGION` | S3 region | Match your bucket's region |
| `NAS_HOST` | NFS server hostname | e.g. `storage.yourdomain.example` |
| `NAS_IP` | NFS server IP | Used by static PV manifests in `clusters/default/` |
| `K3S_VIP` | MetalLB VIP for Traefik LoadBalancer Service | Pick an unused IP in your LAN service subnet |
| `K3S_API_IP` | k3s control-plane node IP | The node running `k3s server` |
| `PIHOLE1_IP` | Primary Pi-hole DNS server IP | Used in network config templates |
| `PIHOLE2_IP` | Secondary Pi-hole DNS server IP | Used in network config templates |
| `LAN_MGMT_CIDR` | Management network CIDR | e.g. `192.168.1.0/24` |
| `LAN_HV_CIDR` | Hypervisor network CIDR | e.g. `192.168.2.0/24` |
| `LAN_SVC_CIDR` | Service/VM network CIDR | e.g. `192.168.3.0/24` |
| `PVE_API_HOST` | Proxmox API IP | IP of any PVE node with API access |
| `PVE_API_USER` | Proxmox API user | e.g. `operator@pve`; needs `VM.Allocate` + `VM.Config.*` |
| `PVE_NODE_1` | Proxmox node 1 hostname | e.g. `__PVE-NODE-1__` |
| `PVE_NODE_2` | Proxmox node 2 hostname | e.g. `__PVE-NODE-2__` |
| `PVE_NODE_3` | Proxmox node 3 hostname | e.g. `__PVE-NODE-3__` |
| `VCS_OWNER` | Your GitHub username | Used by Flux GitRepository source |
| `VCS_REPO` | Your forked repo name | Default: `homelab` |

> **Adapting for your stack:** The `.env` and `cluster-vars.yaml` are the single interface
> between this repo and your specific topology. Terraform modules, Ansible, and Flux all read
> from these variables. If you replace any IaC layer, update the variables it consumes.
> If you do not use Pi-hole, set `PIHOLE1_IP` and `PIHOLE2_IP` to your DNS server IPs
> or remove references to them in the affected manifests.

---

## Step 2: Provision Infrastructure

### 2a: VM Provisioning (Terraform / OpenTofu)

The `terraform/` directory contains three modules: `k3s_nodes`, `dock_nodes`, and
`app-vm-node`. Each provisions VMs on Proxmox using the `telmate/proxmox` provider
against the `ubuntu-24-tpl` cloud image template (vmid 9000 on each PVE node).

```bash
# Provision k3s nodes (repeat pattern for dock_nodes and app-vm-node as needed):
cd terraform/k3s_nodes
cp workers.auto.tfvars.example workers.auto.tfvars
# Edit workers.auto.tfvars — set node counts, IPs, and PVE node assignments
tofu init
tofu plan
tofu apply
```

After apply, all k3s VMs should be reachable via SSH from your workstation.

> **Adapting for your stack:** Replace the Terraform/OpenTofu modules with your VM
> provisioning tool (Pulumi, cloud provider VMs, bare metal, kind, k3d, etc.). The
> required output is a set of nodes with:
> - SSH access from your workstation
> - A network layout matching the IPs in your `cluster-vars.yaml`
> The k3s install step below assumes SSH access to all node IPs.

### 2b: k3s Installation (Ansible)

The Ansible playbooks install k3s in server+agent mode across the provisioned VMs.

```bash
# Copy and edit the inventory file (gitignored)
cp ansible/inventory/hosts.ini.example ansible/inventory/hosts.ini
# Set node IPs and SSH user in hosts.ini

# Run the k3s install playbook
ansible-playbook -i ansible/inventory/hosts.ini ansible/k3s-install.yml
```

After the playbook completes, export the kubeconfig and verify:

```bash
export KUBECONFIG=$HOME/.kube/<your-cluster>.yaml
kubectl get nodes
# Expected: all nodes show STATUS=Ready
```

> **Adapting for your stack:** Replace with your preferred Kubernetes distribution
> (RKE2, Talos, kubeadm, cloud-managed k8s, etc.). The required output is a working
> kubeconfig. Set `KUBECONFIG` before all subsequent steps.
>
> **NFS layer note:** If you use a different NFS provider or a different storage
> backend (Longhorn, Ceph, cloud-native PVCs), update the PV/PVC manifests under
> `clusters/default/<app>/` to match. Static NFS PVs reference `NAS_IP` — update
> these if your storage topology differs.

---

## Step 3: Bootstrap Flux

**Important:** Apply the `cluster-vars` ConfigMap **before** running `flux resume`.
The `flux-system/kustomization.yaml` uses `postBuild.substituteFrom` with
`optional: false` (the default). If the ConfigMap is missing when Flux reconciles,
it will fail immediately with "ConfigMap not found."

The correct bootstrap sequence is:

```bash
export KUBECONFIG=$HOME/.kube/<your-cluster>.yaml

# Step 3.1: Apply the cluster-vars ConfigMap (off-tree real values file)
kubectl apply -f /path/outside/repo/cluster-vars.yaml
# Verify it landed:
kubectl get configmap cluster-vars -n flux-system

# Step 3.2: Apply the flux-system kustomization (registers Flux to watch this repo)
kubectl apply -f flux-system/kustomization.yaml

# Step 3.3: Resume Flux reconciliation
flux resume kustomization flux-system -n flux-system

# Step 3.4: Watch reconciliation progress
flux get kustomization flux-system --watch
# Wait for: READY=True  MESSAGE=Applied revision: main@sha1:<hash>
```

If Flux shows `READY=False` with a message like "ConfigMap cluster-vars not found in
namespace flux-system," re-apply the cluster-vars ConfigMap and then re-run `flux resume`.

> **Adapting for your stack:** If you bootstrapped Flux with `flux bootstrap github`
> instead of the manual `kubectl apply` path above, the kustomization object is
> already present in the cluster. Skip Step 3.2 and just run `flux resume` after
> applying the cluster-vars ConfigMap.

---

## Step 4: Apply Out-of-Band Secrets

All Kubernetes Secrets are applied manually — they are never committed to the repo.
See [SECRETS.md](SECRETS.md) for the complete inventory with apply commands for each
secret.

Apply secrets roughly in this order to minimize `CrashLoopBackOff` while workloads start:

1. **cert-manager ClusterIssuer token** — Cloudflare API token required for DNS-01
   ACME challenge (see cert-manager docs for the exact Secret name and format)
2. **velero-wasabi-creds** — Velero `BackupStorageLocation` goes `Ready` only when
   this secret is present
3. **All app secrets** — can be applied in any order after the above two

The repo uses a `*-creds.template` convention: each secret has a committed template
file with placeholder values, and the real file is gitignored. Example workflow:

```bash
# Example: applying a secret from its template
cp clusters/default/netalert/secret-paloarp-creds.template \
   clusters/default/netalert/secret-paloarp-creds
# Edit the copy — replace REPLACE_WITH_* placeholders with real values
kubectl apply -f clusters/default/netalert/secret-paloarp-creds
# Do NOT commit the real file — it is gitignored by the *-creds pattern
```

Refer to [SECRETS.md](SECRETS.md) for the full list of secrets, their namespaces,
and apply commands.

---

## Step 5: Verify

After Flux has reconciled and secrets are applied, verify the cluster state:

```bash
# Check all Flux kustomizations are reconciling
flux get kustomizations -A

# Check for any non-Running, non-Completed pods
kubectl get pods -A | grep -v Running | grep -v Completed

# Run the drift check — confirms Flux substitution variables are all resolved
bash tools/flux-envsubst-check.sh

# Spot-check an ingress route (replace with your BASE_DOMAIN)
curl -sk https://uptime.<your-domain>/api/status-page/heartbeat/default | head -20
```

Flux should show all kustomizations `READY=True` within 5–10 minutes of bootstrap.
Pods stuck in `CrashLoopBackOff` usually indicate a missing Secret — run
`kubectl describe pod <pod-name> -n <namespace>` to identify which `secretKeyRef`
is unresolved, then apply the missing secret from [SECRETS.md](SECRETS.md).

---

## Upgrading Apps

### Nextcloud: Do Not Skip Minor Versions

> **Warning: Nextcloud requires sequential minor-version upgrades.**
>
> Nextcloud's database migration system expects each intermediate schema version to
> have run before the next one begins. Skipping from v30 directly to v33 causes a
> `CrashLoopBackOff` at pod startup because the migration script finds a version gap
> it cannot bridge. This is not a k8s issue — it is a Nextcloud application constraint.
>
> If you are starting from a Nextcloud backup on an older version, upgrade one minor
> version at a time and verify the pod reaches `READY 1/1` before proceeding:
>
> ```
> clusters/default/nextcloud/deployment.yaml: image: nextcloud:30-apache
> → verify READY 1/1
> clusters/default/nextcloud/deployment.yaml: image: nextcloud:31-apache
> → verify READY 1/1
> clusters/default/nextcloud/deployment.yaml: image: nextcloud:32-apache
> → verify READY 1/1
> clusters/default/nextcloud/deployment.yaml: image: nextcloud:33-apache
> → verify READY 1/1
> ```
>
> Update **both** `clusters/default/nextcloud/deployment.yaml` **and**
> `clusters/default/nextcloud/cronjob.yaml` to the same image tag at each step.

---

## Troubleshooting

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| Flux `READY=False`, "ConfigMap not found" | `cluster-vars` ConfigMap not applied | `kubectl apply -f /path/to/cluster-vars.yaml` then `flux resume kustomization flux-system -n flux-system` |
| Pod `CrashLoopBackOff` | Missing Secret | `kubectl describe pod <pod> -n <ns>`; check SECRETS.md; apply the missing secret |
| cert-manager `Certificate` stuck `Pending` | ClusterIssuer not ready / Cloudflare token missing | Check `kubectl describe clusterissuer letsencrypt-prod`; apply Cloudflare API token secret |
| NFS mount failures | `NAS_IP` wrong or NFS export not configured | Verify NFS export on NAS; check `NAS_IP` in `cluster-vars.yaml` |
| Traefik `LoadBalancer` stays `Pending` | `K3S_VIP` not in MetalLB `IPAddressPool` | Add `K3S_VIP` to MetalLB `IPAddressPool` manifest and reapply |
| Nextcloud `CrashLoopBackOff` after image bump | Skipped minor versions | Restore previous image tag; upgrade one minor version at a time |
| `flux-envsubst-check.sh` reports unresolved vars | Variable missing from `cluster-vars.yaml` or `.env` | Add the missing key and re-apply the ConfigMap; run `flux reconcile kustomization flux-system` |

---

## Reference

- `flux-system/cluster-vars.example.yaml` — committed template for the 21-key ConfigMap
- `SECRETS.md` — complete Secret inventory with apply commands
- `tools/flux-envsubst-check.sh` — drift check: verifies all Flux substitution variables resolve
- `INFRASTRUCTURE.md` — topology diagram and application table
- [FluxCD postBuild substitution docs](https://fluxcd.io/flux/components/kustomize/kustomizations/#post-build-variable-substitution)
- [cert-manager ACME DNS-01 docs](https://cert-manager.io/docs/configuration/acme/dns01/)
- [MetalLB configuration docs](https://metallb.universe.tf/configuration/)
