variable "pm_token_secret" {
  description = "Secret for the bastion-write@pve!write API token. Stored out-of-band (not in this repo)."
  type        = string
  sensitive   = true
}

variable "nodes" {
  description = <<-EOT
    AIL VMs to provision. Default sizing (4 vCPU / 8 GiB / 60 GiB) is the
    lean spec for a single AIL Framework node — enough headroom over the
    ~4-6 GiB working set the upstream installer creates (5 Redis + KVRocks +
    Python workers). Disk grows with the paste corpus; bump per-node if you
    feed AIL from a high-volume source.
  EOT
  type = map(object({
    target_node = string
    ip          = string # e.g. "__LAN-IP__"
    cores       = optional(number, 4)
    memory      = optional(number, 8192)   # MiB
    disk_size   = optional(string, "60G")
  }))
  default = {}
}

variable "lan_gateway" {
  description = "LAN default gateway"
  type        = string
  default     = "__LAN-IP__"
}

variable "lan_dns" {
  description = "DNS servers (pihole1 + pihole2). Proxmox accepts a space-separated list."
  type        = string
  default     = "__PIHOLE1-IP__ __PIHOLE2-IP__"
}

variable "search_domain" {
  description = "Search domain"
  type        = string
  default     = "__BASE-DOMAIN__"
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
