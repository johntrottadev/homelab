variable "pm_token_secret" {
  description = "Secret for the bastion@pve!read API token"
  type        = string
  sensitive   = true
}

variable "workers" {
  description = <<-EOT
    k3s worker nodes to provision. Key is hostname, value is placement/IP.
    Add a new worker by adding a map entry and running `terraform apply`.

    k3s-1/2/5/6/7 are pre-existing and not TF-managed — they were created
    before this module was refactored. Don't try to import them; the
    Telmate provider's efidisk handling forces replacement on import.
  EOT
  type = map(object({
    target_node = string
    ip          = string # e.g. "__LAN-IP__"
  }))
  default = {}
}

variable "lan_gateway" {
  description = "LAN default gateway for workers"
  type        = string
  default     = "REPLACE_WITH_LAN_GATEWAY"
}

variable "lan_dns" {
  description = "DNS servers for workers (pihole1 + pihole2). Proxmox accepts a space-separated list."
  type        = string
  default     = "REPLACE_WITH_LAN_DNS_PAIR"
}

variable "search_domain" {
  description = "Search domain for workers"
  type        = string
  default     = "REPLACE_WITH_BASE_DOMAIN"
}

variable "ci_user" {
  description = "Cloud-init user created on each worker"
  type        = string
  default     = "bastion"
}

variable "ssh_pubkeys" {
  description = "Newline-separated SSH authorized keys for ci_user. Provide via ssh_pubkeys.auto.tfvars."
  type        = string
  sensitive   = false
}
