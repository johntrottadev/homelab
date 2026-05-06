variable "pm_token_secret" {
  description = "Secret for the bastion@pve!read API token"
  type        = string
  sensitive   = true
}

variable "nodes" {
  description = <<-EOT
    Docker host nodes to provision. Key is hostname, value is placement / IP /
    sizing. Add a new node by adding a map entry and running `terraform apply`.

    docker-1 is pre-existing and NOT TF-managed (it predates this module).
    Don't try to import it — Telmate's efidisk handling forces replacement.

    Default sizing (4 vCPU / 16 GiB / 100 GiB) is the docker-2 spec from
    /Volumes/code/homelab/docker-1/MIRROR-PLAN.md. Override per-node if a
    workload needs more.
  EOT
  type = map(object({
    target_node = string
    ip          = string # e.g. "__LAN-IP__"
    cores       = optional(number, 4)
    memory      = optional(number, 16384)  # MiB
    disk_size   = optional(string, "100G")
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
  description = "Cloud-init user created on each node"
  type        = string
  default     = "bastion"
}

variable "ssh_pubkeys" {
  description = "Newline-separated SSH authorized keys for ci_user. Provide via ssh_pubkeys.auto.tfvars."
  type        = string
  sensitive   = false
}
