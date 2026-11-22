# The root module's inputs: every input of the billing-normalizer and
# monitoring-node submodules, under the same name (the normalizer's schedule,
# memory and log retention get a normalizer_ prefix), defaulting to null so
# each submodule applies its own default and validation. The node's `cost` is
# wired here (see main.tf); only its budgets, anomaly floor and workspace tag
# are inputs. Generated from the submodules' variables.tf; keep them in step.

variable "name" {
  description = "The name everything is named for: the node is <name>, the normalizer <name>-normalizer."
  type        = string
}

variable "bucket_name" {
  description = "The billing bucket (the billing-bucket submodule, applied elsewhere): the normalizer reads its raw/ layer and writes normalized/, and the node reads normalized/."
  type        = string
}

variable "normalized_prefix" {
  description = "Where the normalized layer is written: `billing-bucket`'s `normalized_prefix`. No leading or trailing slash."
  type        = string
  default     = null
}

variable "promoted_tags" {
  description = <<-EOT
    Tags promoted out of each row's tag map into their own `x_<tag>` columns, for
    grouping. A tag key is matched as written, as `user:<tag>` or as
    `user_<tag lowercased>`. Changing the list rebuilds every output.
  EOT
  type        = list(string)
  default     = null
}

variable "aws" {
  description = <<-EOT
    The AWS Data Export source, or null for none. `delivery_prefix` is the export's
    `delivery_prefix` (`aws-billing-export`). Rows whose `PublisherName` is in
    `exclude_publishers` are dropped, for a provider also billed directly, such
    as Databricks bought through AWS Marketplace.
  EOT
  type = object({
    delivery_prefix    = string
    exclude_publishers = optional(list(string), [])
  })
  default = null
}

variable "databricks" {
  description = <<-EOT
    The Databricks system-table source, or null for none. `prefix` is where the
    daily job delivers (see the README for its layout). `account_name` names the
    billing account in the rows. `workspace_names` names workspaces the delivered
    workspace table does not; `workspace_projects` gives the `Project` of usage
    that carries none, by workspace ID or name.
  EOT
  type = object({
    prefix             = optional(string, "raw/provider=databricks/source=system-tables")
    account_name       = optional(string, "Databricks")
    workspace_names    = optional(map(string), {})
    workspace_projects = optional(map(string), {})
  })
  default = null
}

variable "runs" {
  description = <<-EOT
    Task-run event records (`runs-1`, see the README), or null for none. `prefixes`
    are where the records are written; `join_tags` are the resource tags whose
    values identify a run, in order, and join its events to its cost rows.
  EOT
  type = object({
    prefixes  = list(string)
    join_tags = list(string)
  })
  default = null
}

variable "normalizer_schedule_expression" {
  description = "How often the normalizer runs, as an EventBridge Scheduler expression. A run with nothing new to read only writes its run record."
  type        = string
  default     = null
}

variable "pandas_layer_arn" {
  description = <<-EOT
    The Lambda layer that provides pyarrow. Null uses the AWS SDK for pandas layer
    for Python 3.13 on arm64 in the function's region (awswrangler 3.18.0).
  EOT
  type        = string
  default     = null
}

variable "normalizer_memory_size" {
  description = <<-EOT
    The function's memory, in MB. A month of AWS line items takes roughly 6 KB per
    row at peak; raise it when a billing period reaches about 150,000 rows.
  EOT
  type        = number
  default     = null
}

variable "normalizer_log_retention_days" {
  description = "Retention of the function's CloudWatch log group, in days."
  type        = number
  default     = null
}

variable "vpc_id" {
  description = "The VPC of the node's subnet."
  type        = string
}

variable "subnet_id" {
  description = "A public subnet for the node. The data volume is created in its availability zone, so moving the node to another zone means a new volume."
  type        = string
}

variable "instance_type" {
  description = "The instance type, arm64 (Graviton). A T type runs with standard CPU credits, so a burst never bills extra; watch its credit balance."
  type        = string
  default     = null
}

variable "ami_name" {
  description = "The exact name of the Amazon Linux 2023 arm64 image to run, e.g. `al2023-ami-2023.12.20261026.1-kernel-6.18-arm64`. Changing it replaces the instance; the data volume is reattached."
  type        = string
}

variable "root_volume_gb" {
  description = "Size of the root volume: the OS, the images and a 2 GB swap file."
  type        = number
  default     = null
}

variable "data_volume_gb" {
  description = "Size of the data volume: Prometheus, Postgres, Grafana and Caddy's state, kept when the instance is replaced."
  type        = number
  default     = null
}

variable "domain" {
  description = "The name Grafana is served at over HTTPS (Caddy, Let's Encrypt). Null: no ingress at all; reach Grafana through a Session Manager port forward."
  type        = string
  default     = null
}

variable "zone_id" {
  description = "The Route 53 hosted zone of `domain`. The node may only upsert its own A record there, at every boot."
  type        = string
  default     = null
}

variable "acme_email" {
  description = "Optional contact address for Let's Encrypt."
  type        = string
  default     = null
}

variable "grafana_admin" {
  description = "The SSM SecureString parameters (default aws/ssm key) holding Grafana's admin user name and password. Set them before the first apply. The node checks them every 5 minutes; a changed password is applied with Grafana's admin password reset."
  type = object({
    user_parameter     = string
    password_parameter = string
  })
}

variable "prometheus_retention" {
  description = "How long Prometheus keeps metrics, and the size it never grows past (the oldest data is dropped first). size_gb is at least 1; keep it well under data_volume_gb."
  type = object({
    time    = optional(string, "365d")
    size_gb = optional(number, 12)
  })
  default = null
}

variable "snapshots" {
  description = "Daily snapshots of the data volume (AWS Backup), kept `keep` days. Without a schedule they run at time_utc (HH:MM); with one, an hour after the stop in the schedule's time zone (03:00 when that falls in 01:00-02:59), so they capture disks shut down cleanly."
  type = object({
    enabled  = optional(bool, false)
    time_utc = optional(string, "03:00")
    keep     = optional(number, 7)
  })
  default = null
}

variable "schedule" {
  description = "Off-hours: the node runs from on to off on the given days, in timezone (an IANA name), and is stopped otherwise. Whole hours, on before off, off may be 24:00 (midnight at the end of the day), at least 4 hours on, days from mon to sun. Avoid 01:00-03:00, when daylight saving changes. null runs the node all day."
  type = object({
    timezone = string
    days     = list(string)
    on       = string
    off      = string
  })
  default = null
}

variable "images" {
  description = "Container images to use instead of the module's digest-pinned defaults, by service name (see the README)."
  type        = map(string)
  default     = null
}

variable "extra_dashboards" {
  description = "More dashboards to provision: \"<Folder>/<name>.json\" (the folder is created in Grafana) to the dashboard's JSON, which needs a uid and a title."
  type        = map(string)
  default     = null
}

variable "extra_alert_rules" {
  description = "More alert rules: a name to a Grafana alerting provisioning document (YAML), provisioned as rules-extra-<name>.json. Every rule needs labels area (host, pipeline or cost) and severity (warning or critical). To remove a rule, keep its uid under deleteRules in the same document."
  type        = map(string)
  default     = null
}

variable "thresholds" {
  description = "Alert thresholds, which also set the dashboard's tile colours and dashed lines. Every attribute is optional and defaults to spec 6.8's numbers. Percentages are of the resource; cpu_credits_percent is of the instance type's maximum balance; container_restarts counts restarts in 15 minutes; the *_days are days. prometheus_history_days warns only while Prometheus is above prometheus_size_percent of its size cap, i.e. when the cap is costing history."
  type = object({
    cpu_percent               = optional(object({ warning = number, critical = number }), { warning = 60, critical = 85 })
    cpu_credits_percent       = optional(object({ warning = number, critical = number }), { warning = 25, critical = 5 })
    memory_percent            = optional(object({ warning = number, critical = number }), { warning = 70, critical = 90 })
    swap_percent              = optional(object({ warning = number, critical = number }), { warning = 25, critical = 75 })
    disk_percent              = optional(object({ warning = number, critical = number }), { warning = 70, critical = 90 })
    disk_full_days            = optional(object({ warning = number, critical = number }), { warning = 7, critical = 2 })
    inodes_percent            = optional(object({ warning = number, critical = number }), { warning = 70, critical = 90 })
    prometheus_size_percent   = optional(object({ warning = number }), { warning = 85 })
    prometheus_history_days   = optional(object({ warning = number }), { warning = 90 })
    container_restarts        = optional(object({ warning = number, critical = number }), { warning = 1, critical = 3 })
    tls_days                  = optional(object({ warning = number, critical = number }), { warning = 14, critical = 3 })
    os_release_update_days    = optional(object({ warning = number }), { warning = 7 })
    normalizer_hours          = optional(object({ warning = number, critical = number }), { warning = 3, critical = 12 })
    aws_charge_days           = optional(object({ warning = number, critical = number }), { warning = 3, critical = 5 })
    databricks_delivery_hours = optional(object({ warning = number, critical = number }), { warning = 36, critical = 60 })
    cost_sync_hours           = optional(object({ warning = number, critical = number }), { warning = 2, critical = 6 })
    anomaly_ratio             = optional(object({ warning = number, critical = number }), { warning = 2, critical = 4 })
    untagged_daily_usd        = optional(object({ warning = number }), { warning = 0.5 })
  })
  default = null
}

variable "slack" {
  description = "Slack notifications: channels (name => the SSM SecureString parameter holding its incoming-webhook URL) and routes (area => channel; areas are host, pipeline and cost, and host is required, since the root policy uses it). null means no notifications: alerts show in Grafana only. Adding a channel is one webhook parameter and one line here."
  type = object({
    channels = map(string)
    routes   = map(string)
  })
  default = null
}

variable "budgets" {
  description = "Monthly budgets in USD for the node's cost alerts: total, per project, and per account by id or name (the node's cost.budgets)."
  type = object({
    total    = optional(number)
    projects = optional(map(number), {})
    accounts = optional(map(number), {})
  })
  default = null
}

variable "anomaly_floor_usd" {
  description = "The node's cost.anomaly_floor_usd: a day must also be this many USD over its 14-day median to be an anomaly."
  type        = number
  default     = null
}

variable "databricks_workspace_tag" {
  description = "The node's cost.databricks_workspace_tag: the tag whose value names a Databricks workspace on its AWS rows (the all-in cost)."
  type        = string
  default     = null
}
