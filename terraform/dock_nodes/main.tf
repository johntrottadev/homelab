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

# Docker host VMs cloned from the ubuntu-tmp template (vmid 107 on __PVE-NODE-1__).
# Adds a dock node: append entry to var.nodes and `terraform apply`.
#
# Why a separate module from k3s_nodes:
# - dock hosts are Ubuntu 24.04, not the kub-tmp k3s base
# - they're docker hosts, not k3s workers (no k3s install path needed)
# - smaller resource footprint (4 vCPU / 16 GiB vs the k3s 8 vCPU / 32 GiB)
# - different cloud-init bootstrap (docker.io + cifs-utils + Komodo Periphery)
resource "proxmox_vm_qemu" "dock" {
  for_each = var.nodes

  name        = each.key
  target_node = each.value.target_node
  clone       = "ubuntu-tmp"
  full_clone  = true

  vm_state = "stopped"

  # Match docker-1 (i440fx default machine) so iface enumerates as ens18, not
  # enp6s18. The ubuntu-tmp template's machine is null (= i440fx), so leaving
  # the field unset preserves that. q35 would re-introduce the enp6s18 quirk
  # documented in k3s_nodes/README.md and break parity with docker-1.
  bios = "ovmf"

  boot = "order=scsi0;net0"

  scsihw = "virtio-scsi-single"

  # Hardware — lighter than k3s workers; mirror plan spec
  sockets  = 1
  cores    = each.value.cores
  memory   = each.value.memory
  cpu_type = "x86-64-v2-aes"

  efidisk {
    efitype = "4m"
    storage = "zfs1"
  }

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

  # Custom cloud-init user-data — installs docker.io, docker-compose-v2,
  # cifs-utils, and the /etc/hosts override for __NAS-HOST__ (load-bearing
  # per access_paths memory: cluster DNS topology forces this on every fresh
  # node). Snippet must be on the PVE node's `local` snippets storage at the
  # path below before apply. See cloud-init/README.md.
  cicustom = "user=local:snippets/dock-node-user-data.yaml"
}
