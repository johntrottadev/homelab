terraform {
  required_providers {
    proxmox = {
      source  = "telmate/proxmox"
      version = "3.0.1-rc6"
    }
  }
}

provider "proxmox" {
  pm_api_url          = "https://__PVE1-IP__:8006/api2/json"
  pm_api_token_id     = "bastion@pve!read"
  pm_api_token_secret = var.pm_token_secret
  pm_tls_insecure     = true
}

# k3s worker VMs cloned from the ubuntu-24-tpl template (vmid 9000), which
# exists on every PVE node so the clone is in-node regardless of target_node.
# Add a node: add an entry to var.workers and `terraform apply`.
resource "proxmox_vm_qemu" "worker" {
  for_each = var.workers

  name        = each.key
  target_node = each.value.target_node
  clone       = "ubuntu-24-tpl"
  full_clone  = true

  # Created stopped; starts after cloud-init drive + config is set below.
  vm_state = "stopped"

  # SeaBIOS (PVE default) — required for the canonical Ubuntu cloud image
  # (`noble-server-cloudimg-amd64.img`), which has a single ext4 partition on
  # GPT and no EFI System Partition. Booting with OVMF lands in the firmware
  # shell and never reaches the OS (validated 2026-05-03). No efidisk needed.
  bios = "seabios"

  # Machine type left at PVE default (i440fx). Note iface ends up as `eth0`
  # (not `ens18`) because canonical's cloud-init NoCloud network-config v1
  # includes an implicit `set-name: eth0`. After bootstrap.sh disables
  # cloud-init network management, eth0 is stable. Fleet state:
  # k3s-1/2/5/6 = ens18 (i440fx, pre-existing); k3s-7 = enp6s18 (q35,
  # outlier built via prior version of this module); kub8+ = eth0
  # (new template). Cluster-side manifests must NOT hard-code iface names.
  # See README "Network interface naming" for the historical context.

  # Enable qemu-guest-agent virtio-serial port. Ubuntu 24.04's
  # qemu-guest-agent.service is udev-triggered on /dev/virtio-ports/...;
  # without this flag the port doesn't exist and the service can't start.
  agent = 1

  # Boot order: scsi0 first, net0 as PXE fallback
  boot = "order=scsi0;net0"

  # Template OS has initramfs drivers for virtio-scsi-single — lsi (provider
  # default) leaves the guest unable to find its root disk.
  scsihw = "virtio-scsi-single"

  # Hardware — matches template sizing
  sockets  = 1
  cores    = 8
  memory   = 32768
  cpu_type = "x86-64-v2-aes"

  disk {
    slot    = "scsi0"
    type    = "disk"
    storage = "zfs1"
    size    = "100G"
  }

  # Cloud-init CD-ROM — required for ipconfig0/sshkeys/etc. to reach the guest.
  disk {
    slot    = "ide2"
    type    = "cloudinit"
    storage = "zfs1"
  }

  network {
    id     = 0
    model  = "virtio"
    bridge = "vmbr1"
  }

  # Cloud-init: static IP, user, SSH keys, DNS. Guest picks these up on boot.
  ipconfig0    = "ip=${each.value.ip}/24,gw=${var.lan_gateway}"
  ciuser       = var.ci_user
  sshkeys      = var.ssh_pubkeys
  nameserver   = var.lan_dns
  searchdomain = var.search_domain

  # NB: no cicustom. PVE's snippet distribution API doesn't support uploading
  # to `snippets` content type via API token (only iso/vztmpl/import). Rather
  # than chase a per-PVE-node SSH workaround, the equivalent bootstrap work
  # (disk grow, cloud-init network disable, nfs-common install) runs as a
  # post-apply `bootstrap.sh` over SSH after the VM is up. K3s install itself
  # remains operator-driven (curl ... | sh -s - --server <k3s-1>). See
  # cloud-init/bootstrap.sh and README.md "Post-clone runbook".
}
