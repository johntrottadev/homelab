# k3s_nodes Terraform module

ProxMox VM provisioner for new k3s worker nodes. Clones from `ubuntu-24-tpl`
(vmid 9000), which exists on every PVE node so the clone is in-node
regardless of `target_node`.

## Status

- **Pre-existing nodes (k3s-1, k3s-2, k3s-5, k3s-6, k3s-7) are NOT TF-managed.** They were created before this module was refactored. Don't try to import them — the Telmate provider's efidisk handling forces replacement on import. They live in tribal-knowledge land.
- This module is for **net-new workers only** (kub8, kub9, ...).

Add a worker:

```hcl
# in *.auto.tfvars
workers = {
  kub8 = { target_node = "__PVE-NODE-3__", ip = "__LAN-IP__" }
}
```

Then `terraform apply`, run `bootstrap.sh` over SSH (see "Post-clone runbook"
below), then install k3s manually (operator step — OUT of scope for this
module). New VMs clone from `ubuntu-24-tpl` and get cloud-init networking
on first boot.

## Network interface naming — known divergence

**Workers created via this module come up with iface name `eth0`.** Cloud-init's
NoCloud network-config v1 (what PVE generates from `ipconfig0`) includes an
implicit `set-name: eth0` directive that renames the underlying predictable
name. After `bootstrap.sh` disables cloud-init network management on subsequent
boots, the existing `/etc/netplan/50-cloud-init.yaml` keeps eth0 stable.

Fleet state:

| Nodes | Machine type | Iface name | TF-managed? |
|---|---|---|---|
| k3s-1, k3s-2, k3s-5, k3s-6 | i440fx | `ens18` | No (pre-existing) |
| k3s-7 | q35 | `enp6s18` | No (built via prior version of this module) |
| kub8+ (this module today) | i440fx | `eth0` | Yes (canonical cloud-image + cloud-init set-name) |

Three different iface names across the fleet. **Don't hard-code iface names
anywhere** — see next section.

### What this means for cluster-side manifests

**Don't hard-code interface names** in any DaemonSet that needs to bind to a
host interface (kube-vip, MetalLB speaker, Calico/Cilium with explicit iface,
etc.). Use auto-detection.

For kube-vip specifically (Phase 13 reference implementation), the working
pattern is:

```yaml
env:
  - name: vip_interface
    value: ""              # empty → auto-detect default-route iface
  - name: vip_subnet
    value: "24"            # bare prefix length, NOT a CIDR
```

**Note on `vip_subnet`:** kube-vip's address builder concatenates
`address + "/" + subnet`, so `vip_subnet=__LAN-SVC-CIDR__` produces the malformed
CIDR `__K3S-VIP__/__LAN-SVC-CIDR__` and the leader silently fails to add the
service. Always use the bare prefix length. (Cost us ~4 min of mid-cutover
debugging on Phase 13.)

### What NOT to do

- **Don't try to standardize the existing fleet** by renaming k3s-7's iface
  to `ens18` (or k3s-2/5/6's to `enp6s18`). The OS-level renames are fragile
  and require reboots; we already learned this the hard way (Phase 13
  k3s-7-iface-rename PARTIAL outcome). Cluster-side auto-detect manifests
  absorb the heterogeneity.

## Bootstrap is post-apply, not cicustom

Earlier versions used `cicustom` with a `k3s-worker-user-data.yaml` snippet
that required manual upload to each PVE node's `/var/lib/vz/snippets/`. PVE's
API token can't write to snippets storage, and per-PVE-node SSH workarounds
weren't worth the complexity.

The equivalent bootstrap (disk grow, cloud-init network lockdown,
nfs-common install) now runs as a post-apply shell script over SSH. Idempotent
and re-runnable.

```bash
# After terraform apply finishes and the new VM has SSH up:
ssh bastion@<new-ip> 'sudo bash -s' < cloud-init/bootstrap.sh
```

`nfs-common` is critical — without it, pods with NFS-backed PVCs scheduled
to a fresh worker hang `ContainerCreating` with "mount.nfs helper missing".
Discovered on k3s-7 post-rebuild (2026-04-27).

## Provider note

The `telmate/proxmox` provider 3.0.1-rc6 has known issues with importing existing VMs (efidisk handling forces replacement). Do NOT try to import k3s-1-7 to bring them under TF management. Future re-architecture would need a greenfield rebuild to migrate fully to TF.

## Post-clone runbook

After `terraform apply`:

```bash
# 1. Run bootstrap over SSH (disk grow, cloud-init network lockdown,
#    nfs-common). Idempotent — re-run anytime.
ssh bastion@<new-ip> 'sudo bash -s' < cloud-init/bootstrap.sh

# 2. Verify the box is in a good state.
ssh bastion@<new-ip> "hostname && df -h / && ip -br link show"
#   Expect: <hostname>; / near full disk size; ens18 with the assigned IP
#   (may show 'eth0' on first boot before bootstrap.sh ran — re-run script
#   then reboot, or just `netplan apply` after disabling cloud-init network).

# 3. Install k3s agent (operator step — outside this module's scope):
ssh bastion@__K3S-API-IP__ 'sudo cat /var/lib/rancher/k3s/server/node-token'
# then on the new worker:
curl -sfL https://get.k3s.io | K3S_URL=https://__K3S-API-IP__:6443 \
  K3S_TOKEN=<token> sh -s - agent

# 4. Verify cluster join from k3s-1:
ssh k3s-1 "kubectl get nodes -o wide"

# 5. If you're adding a kube-vip-style DaemonSet that needs vip_interface:
#    DON'T set vip_interface=eth0 or any concrete name.
#    Use vip_interface=\"\" + vip_subnet=24 (bare prefix length).
```

## References

- Phase 13 incident: `.planning/phases/13-kube-vip-cluster-vip-loadbalancer/13-03-SUMMARY.md` (the vip_subnet bug)
- Phase 13 iface findings: `.planning/phases/13-kube-vip-cluster-vip-loadbalancer/13-02-SUMMARY.md` (k3s-7 enp6s18 discovery)
- Original todo: `.planning/todos/pending/k3s-7-iface-naming-iac-fix.md` (resolved by this README)
