terraform {
  required_providers {
    proxmox = {
      source  = "telmate/proxmox"
      version = "3.0.1-rc9"
    }
  }
}

provider "proxmox" {
  pm_api_url          = "https://__PVE1-IP__:8006/api2/json"
  # Token-id rotated 2026-05-04: old `bastion@pve!read` is gone.
  # Use `bastion-audit@pve!read` for read-only TF planning, or a write-capable
  # token for apply (the current bastion-write@pve!write has Administrator @ /).
  pm_api_token_id     = "bastion-write@pve!write"
  pm_api_token_secret = var.pm_token_secret
  pm_tls_insecure     = true
}

# AIL Framework VM — single-node Debian/Ubuntu host that runs the full AIL
# stack (5 Redis instances + KVRocks + Python workers + UI). Upstream ships
# only an `installing_deps.sh` bare-metal installer; there is no upstream
# Dockerfile or compose, so containerizing this would mean owning a custom
# Dockerfile against a moving target. A dedicated VM is the lowest-pain path.
#
# Lacus (the capture system AIL talks to over HTTP) lives on docker-2 instead —
# upstream ships a working compose for it. See docker-2/lacus/compose.yaml.
#
# Sizing: 4 vCPU / 8 GiB / 60 GiB. Researcher reports ~4-6 GiB working set
# under load (5 Redis + KVRocks + Python). Disk is sized for paste corpus
# growth; KVRocks and PASTES live on local disk for write throughput. Off-site
# durability comes from Kopia → Wasabi (see cloud-init/kopia-backup.sh re-use).
resource "proxmox_vm_qemu" "app-vm" {
  for_each = var.nodes

  name        = each.key
  target_node = each.value.target_node
  clone       = "ubuntu-24-tpl"
  full_clone  = true

  vm_state = "stopped"

  # SeaBIOS — same constraint as dock_nodes: canonical Ubuntu cloud image
  # is GPT+ext4 with no EFI System Partition; OVMF lands in firmware shell.
  bios = "seabios"

  agent = 1

  boot   = "order=scsi0;net0"
  scsihw = "virtio-scsi-single"

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

  # No cicustom — same reason as dock_nodes (PVE API token can't upload to
  # snippets). Bootstrap (qemu-guest-agent install, AIL deps, repo clone,
  # installer run, kopia backup setup) runs as a post-apply SSH script:
  #   ssh bastion@<ip> 'sudo bash -s' < cloud-init/bootstrap.sh
  #   ssh bastion@<ip> 'sudo bash -s' < cloud-init/app-vm-install.sh
}
