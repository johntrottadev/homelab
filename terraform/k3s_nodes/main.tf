terraform {
  required_providers {
    proxmox = {
      source  = "telmate/proxmox"
      version = "3.0.1-rc6"
    }
  }
}

provider "proxmox" {
  pm_api_url   = "https://__PVE1-IP__:8006/api2/json"  # Replace with your Proxmox URL
  pm_user      = "terraform@pve"                                        # Or your specific Proxmox user
  pm_password  = "w&1l6MdUp&44lQ#pVlYX%M3x"                                   # Replace with your password or use an environment variable
  pm_tls_insecure = true
}
resource "proxmox_vm_qemu" "ubuntu_vm" {
#  vmid        = 110
  name        = "k3s-5"
  target_node = "__PVE-NODE-2__"
  clone       = "kub-tmp"
  full_clone  = true

  # ─── Power state ─────────────────────────────────
  # Keep it off while we configure BIOS/EFI
  vm_state = "stopped"

  # ─── Firmware & machine ──────────────────────────
  bios    = "ovmf"    # switch to UEFI
  machine = "q35"     # required for OVMF firmware :contentReference[oaicite:0]{index=0}

  # ─── EFI disk ────────────────────────────────────
  # Proxmox will automatically pre-load keys on this disk
  efidisk {
    efitype = "4m"        # typical size
    storage = "zfs1"      # where to store the EFI volume
  }                       # :contentReference[oaicite:1]{index=1}

  # ─── Boot order ──────────────────────────────────
  # Look at the EFI disk first, then your main scsi0 disk
  boot = "order=scsi0"  

  # ─── CPU & RAM ──────────────────────────────────
  sockets    = 1
  cores      = 8
  memory     = 32768
  cpu_type   = "x86-64-v2-aes"   # your chosen CPU model :contentReference[oaicite:2]{index=2}

  # ─── Disks & NIC ───────────────────────────────
  disk {
    slot    = "scsi0"
    type    = "disk"
    storage = "zfs1"
    size    = "100G"
  }

  network {
    id      = 0
    model   = "virtio"
    bridge  = "vmbr1"
  }
}
