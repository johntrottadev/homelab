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

# k3s worker VMs cloned from the kub-tmp template.
# Add a node: add an entry to var.workers and `terraform apply`.
resource "proxmox_vm_qemu" "worker" {
  for_each = var.workers

  name        = each.key
  target_node = each.value.target_node
  clone       = "kub-tmp"
  full_clone  = true

  # Created stopped; starts after cloud-init drive + config is set below.
  vm_state = "stopped"

  # UEFI + q35 machine to match template expectations
  bios    = "ovmf"
  machine = "q35"

  # Boot order: scsi0 first, net0 as PXE fallback (matches template)
  boot = "order=scsi0;net0"

  # Template OS has initramfs drivers for virtio-scsi-single — lsi (provider
  # default) leaves the guest unable to find its root disk and UEFI sits at
  # "no bootable device". This is the critical template-matching knob.
  scsihw = "virtio-scsi-single"

  # Hardware — matches template sizing
  sockets  = 1
  cores    = 8
  memory   = 32768
  cpu_type = "x86-64-v2-aes"

  efidisk {
    efitype = "4m"
    storage = "zfs1"
  }

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

  # Custom cloud-init user-data — installs nfs-common so NFS-backed PVCs mount
  # cleanly on first boot. Snippet must be present on the PVE node's `local`
  # snippets storage at the path below before apply. See cloud-init/README.
  cicustom = "user=local:snippets/k3s-worker-user-data.yaml"
}
