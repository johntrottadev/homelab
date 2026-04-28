# k3s_nodes Terraform module

ProxMox VM provisioner for new k3s worker nodes. Clones from `kub-tmp` template (vmid 108 on __PVE-NODE-2__).

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

Then `terraform apply`. The new VM clones from `kub-tmp`, gets cloud-init networking, and joins the cluster after k3s is installed (k3s install is OUT of scope for this module — operator runs `curl ... | sh -s - --server <k3s-1>` post-clone).

## Network interface naming — known divergence (Phase 13 finding)

**Workers created via this module will get systemd predictable interface name `enp6s18`, NOT `ens18`** like the pre-existing nodes.

Root cause: `main.tf` sets `machine = "q35"` (line 32). With q35, the virtio-net NIC enumerates on PCI bus 6 slot 18 → systemd names it `enp6s18`. The pre-existing k3s-1/2/5/6 use the older `pc-i440fx` machine type which puts the NIC on a hot-plug slot → systemd names it `ens18`. k3s-7 was created via this module (q35) and exposes `enp6s18`.

There's also a layered cloud-init quirk: ProxMox's `ipconfig0` field generates a NoCloud network-config that includes `match: macaddress` + `set-name: eth0`, which renames whatever the underlying name is to `eth0`. So fresh k3s-7-style nodes show `eth0` from inside the OS until cloud-init's network management is disabled.

### What this means for cluster-side manifests

**Don't hard-code interface names** in any DaemonSet that needs to bind to a host interface (kube-vip, MetalLB speaker, Calico/Cilium with explicit iface, etc.). Use auto-detection.

For kube-vip specifically (Phase 13 reference implementation), the working pattern is:

```yaml
env:
  - name: vip_interface
    value: ""              # empty → auto-detect default-route iface
  - name: vip_subnet
    value: "24"            # bare prefix length, NOT a CIDR
```

**Note on `vip_subnet`:** kube-vip's address builder concatenates `address + "/" + subnet`, so `vip_subnet=__LAN-SVC-CIDR__` produces the malformed CIDR `__K3S-VIP__/__LAN-SVC-CIDR__` and the leader silently fails to add the service. Always use the bare prefix length. (Cost us ~4 min of mid-cutover debugging on Phase 13.)

### Optional future hardening (not done today)

If you want fresh workers to come up with stable iface names AND no cloud-init `set-name: eth0` rename, add a `cicustom` snippet to the Terraform that disables cloud-init network management:

```hcl
# Snippet in main.tf (NOT applied — design only):
cicustom = "user=local:snippets/k3s-worker-user-data.yaml"
# k3s-worker-user-data.yaml content:
#   #cloud-config
#   write_files:
#     - path: /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
#       content: "network: {config: disabled}"
#     - path: /etc/netplan/01-static.yaml
#       permissions: '0600'
#       content: |
#         network:
#           version: 2
#           renderer: networkd
#           ethernets:
#             enp6s18:
#               addresses: ["${each.value.ip}/24"]
#               nameservers: { addresses: [__PIHOLE1-IP__], search: [__BASE-DOMAIN__] }
#               routes: [{ to: default, via: __LAN-IP__ }]
#   runcmd:
#     - netplan apply
```

This locks the iface name to `enp6s18` and bypasses ProxMox's cloud-init-generated `set-name: eth0`. The trade-off is that the snippet hard-codes `enp6s18`, which only works on q35 machines. If you switch to pc-i440fx, the snippet needs to switch to `ens18`.

Until then: cluster-side auto-detect manifests (already in place for kube-vip per Phase 13) absorb the heterogeneity. New workers via this module just work alongside the pre-existing fleet.

### What NOT to do

- **Don't change `machine = "q35"` to `pc-i440fx`** to "fix" the iface name. q35 is the modern recommendation; downgrading sacrifices PCIe topology for trivial cosmetic naming consistency. The auto-detect pattern is the right answer.
- **Don't try to standardize the existing fleet** by renaming k3s-2/5/6's iface to `enp6s18` (or vice versa). The OS-level renames are fragile and require reboots; we already learned this the hard way (Phase 13 k3s-7-iface-rename PARTIAL outcome).

## Provider note

The `telmate/proxmox` provider 3.0.1-rc6 has known issues with importing existing VMs (efidisk handling forces replacement). Do NOT try to import k3s-1-7 to bring them under TF management. Future re-architecture would need a greenfield rebuild to migrate fully to TF.

## Verifying a fresh worker

After `terraform apply`, before installing k3s:

```bash
# 1. Confirm SSH works (cloud-init created the bastion user with the keys from
#    ssh_pubkeys.auto.tfvars). Add the new IP to ~/.ssh/config Host line first.
ssh bastion@<new-ip> "hostname && ip -br link show"
# Expect: <hostname>; ens18 OR enp6s18 (depending on machine type, see above)

# 2. After k3s join, verify the predictable iface name from cluster side:
ssh k3s-1 "sudo kubectl debug node/<new-node> -it --image=busybox -- chroot /host ip -br link show"

# 3. If you're adding a kube-vip-style DaemonSet that needs vip_interface:
#    DON'T set vip_interface=eth0 or any concrete name.
#    Use vip_interface=\"\" + vip_subnet=24 (bare prefix length).
```

## References

- Phase 13 incident: `.planning/phases/13-kube-vip-cluster-vip-loadbalancer/13-03-SUMMARY.md` (the vip_subnet bug)
- Phase 13 iface findings: `.planning/phases/13-kube-vip-cluster-vip-loadbalancer/13-02-SUMMARY.md` (k3s-7 enp6s18 discovery)
- Original todo: `.planning/todos/pending/k3s-7-iface-naming-iac-fix.md` (resolved by this README)
