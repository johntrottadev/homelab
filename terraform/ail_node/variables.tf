variable "pm_token_secret" {
  description = "Secret for the bastion-write@pve!write API token. Stored out-of-band (not in this repo)."
  type        = string
  sensitive   = true
}

variable "nodes" {
  description = <<-EOT
    AIL VMs to provision. Default sizing (4 vCPU / 16 GiB / 60 GiB). The
    8 GiB lean spec ran at ~97% RAM with all modules enabled + concurrent
    Retro_Hunt jobs and no swap, firing NodeMemoryHighUtilization. Steady
    real usage is ~7.5 GiB; 16 GiB gives genuine headroom. Disk grows with
    the paste corpus; bump per-node if you feed AIL from a high-volume source.
  EOT
  type = map(object({
    target_node = string
    ip          = string # e.g. "__LAN-IP__"
    cores       = optional(number, 4)
    memory      = optional(number, 16384)  # MiB — bumped from 8192 (OOM/alert fix)
    disk_size   = optional(string, "60G")
  }))
  default = {}
}

variable "lan_gateway" {
  description = "LAN default gateway"
  type        = string
  default     = "REPLACE_WITH_LAN_GATEWAY"
}

variable "lan_dns" {
  description = "DNS servers (pihole1 + pihole2). Proxmox accepts a space-separated list."
  type        = string
  default     = "REPLACE_WITH_LAN_DNS_PAIR"
}

variable "search_domain" {
  description = "Search domain"
  type        = string
  default     = "REPLACE_WITH_BASE_DOMAIN"
}

variable "ci_user" {
  description = "Cloud-init user created on the VM"
  type        = string
  default     = "bastion"
}

variable "ssh_pubkeys" {
  description = "Newline-separated SSH authorized keys for ci_user. Provide via ssh_pubkeys.auto.tfvars."
  type        = string
  sensitive   = false
}
