# The monitoring-node module validates what callers give it; these are the
# already-checked values it passes on.

variable "region" {
  description = "The node's region, for the CloudWatch data source."
  type        = string
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
