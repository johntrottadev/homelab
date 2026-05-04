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

# Docker host VMs cloned from the ubuntu-24-tpl template (vmid 9000), which
# exists on every PVE node so the clone is in-node regardless of target_node.
# Adds a dock node: append entry to var.nodes and `terraform apply`.
#
# Why a separate module from k3s_nodes:
# - they're docker hosts, not k3s workers (no k3s install path needed)
# - smaller resource footprint (4 vCPU / 16 GiB vs the k3s 8 vCPU / 32 GiB)
# - different post-apply bootstrap (docker.io + cifs-utils + Komodo Periphery)
resource "proxmox_vm_qemu" "dock" {
  for_each = var.nodes

  name        = each.key
  target_node = each.value.target_node
  clone       = "ubuntu-24-tpl"
  full_clone  = true

  vm_state = "stopped"

  # SeaBIOS (PVE default) — required for the canonical Ubuntu cloud image
  # (`noble-server-cloudimg-amd64.img`), which has a single ext4 partition on
  # GPT and no EFI System Partition. Booting with OVMF lands in the firmware
  # shell and never reaches the OS (validated 2026-05-03 against ubuntu-24-tpl).
  # No efidisk needed under SeaBIOS.
  bios = "seabios"

  # Machine type left at PVE default (i440fx). Note iface name ends up as
  # `eth0` (not `ens18`) because canonical's cloud-init NoCloud network-config
  # v1 includes an implicit `set-name: eth0`. After bootstrap.sh disables
  # cloud-init network management, the existing /etc/netplan/50-cloud-init.yaml
  # keeps eth0 stable. docker-1/docker-2 are still ens18 (predate this template);
  # functional, just heterogeneous.

  # Enable qemu-guest-agent virtio-serial port. Ubuntu 24.04's
  # qemu-guest-agent.service is udev-triggered on /dev/virtio-ports/...; without
  # this flag the port doesn't exist and the service can't start.
  agent = 1

  boot = "order=scsi0;net0"

  scsihw = "virtio-scsi-single"

  # Hardware — lighter than k3s workers; mirror plan spec
  sockets  = 1
  cores    = each.value.cores
  memory   = each.value.memory
  cpu_type = "x86-64-v2-aes"

  disk {
    slot    = "scsi0"
    type    = "disk"
    storage = "zfs1"
    size    = each.value.disk_size
  }

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

  ipconfig0    = "ip=${each.value.ip}/24,gw=${var.lan_gateway}"
  ciuser       = var.ci_user
  sshkeys      = var.ssh_pubkeys
  nameserver   = var.lan_dns
  searchdomain = var.search_domain

  # NB: no cicustom. PVE's snippet distribution API doesn't support uploading
  # to `snippets` content type via API token (only iso/vztmpl/import). Rather
  # than chase a shared snippets storage workaround, the equivalent bootstrap
  # work — apt installs (docker, cifs-utils), NAS hosts pin, fstab CIFS line,
  # bastion docker group — runs as a post-apply `bootstrap.sh` over SSH after
  # the VM is up. See cloud-init/bootstrap.sh and README.md "Post-clone runbook".
}
