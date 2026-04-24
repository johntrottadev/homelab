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

resource "proxmox_vm_qemu" "k3s-7" {
  name        = "k3s-7"
  target_node = "__PVE-NODE-2__"
  clone       = "kub-tmp"
  full_clone  = true

  vm_state = "stopped"

  bios    = "ovmf"
  machine = "q35"

  efidisk {
    efitype = "4m"
    storage = "zfs1"
  }

  boot = "order=scsi0"

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

  network {
    id     = 0
    model  = "virtio"
    bridge = "vmbr1"
  }
}
