# The monitoring-node module validates what callers give it; these are the
# already-checked values it passes on.

variable "region" {
  description = "The node's region, for the CloudWatch data source."
  type        = string
}

variable "instance_id" {
  description = "The node's instance, for its CloudWatch panels and rules."
  type        = string
}

variable "instance_type" {
  description = "The node's instance type, which says whether it has CPU credits and how many it can hold."
  type        = string
}

variable "domain" {
  description = "The node's public name, or null. With it come the TLS panels and rules."
  type        = string
  default     = null
}

variable "thresholds" {
  description = "The alert thresholds, resolved by the monitoring-node module (its thresholds variable holds the defaults and checks them)."
  type = object({
    cpu_percent             = object({ warning = number, critical = number })
    cpu_credits_percent     = object({ warning = number, critical = number })
    memory_percent          = object({ warning = number, critical = number })
    swap_percent            = object({ warning = number, critical = number })
    disk_percent            = object({ warning = number, critical = number })
    disk_full_days          = object({ warning = number, critical = number })
    inodes_percent          = object({ warning = number, critical = number })
    prometheus_size_percent = object({ warning = number })
    prometheus_history_days = object({ warning = number })
    container_restarts      = object({ warning = number, critical = number })
    tls_days                = object({ warning = number, critical = number })
    os_release_update_days  = object({ warning = number })
  })
}

variable "extra_dashboards" {
  description = "More dashboards: \"<Folder>/<name>.json\" to the dashboard's JSON."
  type        = map(string)
  default     = {}
}

variable "extra_alert_rules" {
  description = "More alert rules: a name to a Grafana alerting provisioning document (YAML), provisioned as rules-extra-<name>.json."
  type        = map(string)
  default     = {}
}
