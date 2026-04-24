variable "pm_token_secret" {
  description = "Secret for the bastion@pve!read API token"
  type        = string
  sensitive   = true
}

variable "workers" {
  description = "k3s worker nodes to provision. Key is hostname, value is placement/IP."
  type = map(object({
    target_node = string
    ip          = string # e.g. "__LAN-IP__"
  }))
  default = {
    k3s-7 = { target_node = "__PVE-NODE-2__", ip = "__LAN-IP__" }
  }
}

variable "lan_gateway" {
  description = "LAN default gateway for workers"
  type        = string
  default     = "__LAN-IP__"
}

variable "lan_dns" {
  description = "DNS server for workers (pihole)"
  type        = string
  default     = "__PIHOLE1-IP__"
}

variable "search_domain" {
  description = "Search domain for workers"
  type        = string
  default     = "__BASE-DOMAIN__"
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
