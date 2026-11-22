variable "name" {
  description = "Names the instance, its role, security group, data volume (`<name>-data`), config bucket (`<name>-config-<account>`) and parameters (`/<name>/node/…`)."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9-]{1,40}$", var.name))
    error_message = "name must be 1 to 40 lowercase letters, digits or hyphens."
  }
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
  default     = "t9g.medium"
}

variable "ami_name" {
  description = "The exact name of the Amazon Linux 2023 arm64 image to run, e.g. `al2023-ami-2023.12.20261026.1-kernel-6.18-arm64`. Changing it replaces the instance; the data volume is reattached."
  type        = string

  validation {
    condition     = length(trimspace(var.ami_name)) > 0
    error_message = "ami_name must name an image."
  }
}

variable "root_volume_gb" {
  description = "Size of the root volume: the OS, the images and a 2 GB swap file."
  type        = number
  default     = 12

  validation {
    condition     = var.root_volume_gb >= 8
    error_message = "root_volume_gb must be at least 8."
  }
}

variable "data_volume_gb" {
  description = "Size of the data volume: Prometheus, Postgres, Grafana and Caddy's state, kept when the instance is replaced."
  type        = number
  default     = 30

  validation {
    condition     = var.data_volume_gb >= 10
    error_message = "data_volume_gb must be at least 10."
  }
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

  validation {
    condition     = var.domain == null || var.zone_id != null
    error_message = "zone_id is required when domain is set."
  }
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
  default = {}

  validation {
    condition     = var.prometheus_retention.size_gb >= 1
    error_message = "prometheus_retention.size_gb is at least 1: the cap is what keeps Prometheus from filling the data volume (0 would turn it off)."
  }
}

variable "snapshots" {
  description = "Daily snapshots of the data volume (Data Lifecycle Manager), at time_utc, keeping the last `keep`."
  type = object({
    enabled  = optional(bool, false)
    time_utc = optional(string, "03:00")
    keep     = optional(number, 7)
  })
  default = {}
}

variable "images" {
  description = "Container images to use instead of the module's digest-pinned defaults, by service name (see the README)."
  type        = map(string)
  default     = {}
}

variable "extra_dashboards" {
  description = "More dashboards to provision: \"<Folder>/<name>.json\" (the folder is created in Grafana) to the dashboard's JSON, which needs a uid and a title."
  type        = map(string)
  default     = {}

  validation {
    condition     = alltrue([for path in keys(var.extra_dashboards) : can(regex("^[A-Za-z0-9 _-]+/[a-z0-9-]+\\.json$", path))])
    error_message = "Each extra_dashboards key is \"<Folder>/<name>.json\": a folder of letters, digits, spaces, _ or -, and a lowercase name."
  }
}

variable "extra_alert_rules" {
  description = "More alert rules: a name to a Grafana alerting provisioning document (YAML), provisioned as rules-extra-<name>.json. Every rule needs labels area (host, pipeline or cost) and severity (warning or critical). To remove a rule, keep its uid under deleteRules in the same document."
  type        = map(string)
  default     = {}

  validation {
    condition     = alltrue([for name in keys(var.extra_alert_rules) : can(regex("^[a-z0-9-]+$", name))])
    error_message = "Each extra_alert_rules key is lowercase letters, digits and -."
  }
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
  default = {}

  validation {
    condition = alltrue([
      for t in [var.thresholds.cpu_percent, var.thresholds.memory_percent, var.thresholds.swap_percent, var.thresholds.disk_percent, var.thresholds.inodes_percent, var.thresholds.container_restarts,
      var.thresholds.normalizer_hours, var.thresholds.aws_charge_days, var.thresholds.databricks_delivery_hours, var.thresholds.cost_sync_hours, var.thresholds.anomaly_ratio] :
      t.warning < t.critical
    ])
    error_message = "For cpu, memory, swap, disk, inodes, container_restarts and the pipeline thresholds, higher is worse: warning must be below critical."
  }

  validation {
    condition = alltrue([
      for t in [var.thresholds.cpu_credits_percent, var.thresholds.disk_full_days, var.thresholds.tls_days] :
      t.warning > t.critical
    ])
    error_message = "For cpu_credits_percent, disk_full_days and tls_days, lower is worse: warning must be above critical."
  }

  validation {
    condition = alltrue([
      for v in flatten([
        for t in [var.thresholds.cpu_percent, var.thresholds.cpu_credits_percent, var.thresholds.memory_percent, var.thresholds.swap_percent, var.thresholds.disk_percent, var.thresholds.inodes_percent] : [t.warning, t.critical]
      ]) : v > 0 && v <= 100
    ]) && var.thresholds.prometheus_size_percent.warning > 0 && var.thresholds.prometheus_size_percent.warning <= 100
    error_message = "Percentages are above 0 and at most 100."
  }

  validation {
    condition     = alltrue([for v in [var.thresholds.container_restarts.warning, var.thresholds.container_restarts.critical] : v >= 1 && floor(v) == v])
    error_message = "container_restarts are whole numbers of restarts, at least 1."
  }

  validation {
    condition     = var.thresholds.anomaly_ratio.warning > 1 && var.thresholds.untagged_daily_usd.warning >= 0
    error_message = "anomaly_ratio is a multiple of the 14-day median, so warning is above 1; untagged_daily_usd is at least 0."
  }
}

variable "slack" {
  description = "Slack notifications: channels (name => the SSM SecureString parameter holding its incoming-webhook URL) and routes (area => channel; areas are host, pipeline and cost, and host is required, since the root policy uses it). null means no notifications: alerts show in Grafana only. Adding a channel is one webhook parameter and one line here."
  type = object({
    channels = map(string)
    routes   = map(string)
  })
  default = null

  validation {
    condition     = var.slack == null ? true : length(var.slack.channels) > 0 && alltrue([for c in keys(var.slack.channels) : can(regex("^[a-z][a-z0-9-]{0,29}$", c))])
    error_message = "slack.channels needs at least one channel, each named with a lowercase letter, then lowercase letters, digits or - (at most 30)."
  }

  validation {
    condition     = var.slack == null ? true : alltrue([for p in values(var.slack.channels) : startswith(p, "/")])
    error_message = "Each slack channel's value is the full name of its SSM parameter, starting with /."
  }

  validation {
    condition     = var.slack == null ? true : contains(keys(var.slack.routes), "host") && alltrue([for a in keys(var.slack.routes) : contains(["host", "pipeline", "cost"], a)])
    error_message = "slack.routes maps areas (host, pipeline, cost) to channels, and must route host."
  }

  validation {
    condition     = var.slack == null ? true : alltrue([for c in values(var.slack.routes) : contains(keys(var.slack.channels), c)])
    error_message = "Every slack route names one of slack.channels."
  }
}

variable "cost" {
  description = "The cost data, read from the billing bucket's normalized/ layer (the billing-normalizer's CSV twins): bucket, the normalizer's prefix, the providers expected there (for the staleness alerts), the tags a task run's cost rows are joined on, monthly budgets in USD (total, per project, per account by id or name), the anomaly floor (the day's spend must also be this many USD over its 14-day median), and the tag whose value names a Databricks workspace on its AWS resources (the all-in cost; it must be an active cost allocation tag). null for a host-only node. With it, cost-sync keeps the cost database on the node and Grafana reads it."
  type = object({
    bucket            = string
    normalized_prefix = optional(string, "normalized")
    providers         = optional(set(string), ["aws", "databricks"])
    run_join_tags     = optional(list(string), ["RunId", "TaskId"])
    budgets = optional(object({
      total    = optional(number)
      projects = optional(map(number), {})
      accounts = optional(map(number), {})
    }), {})
    anomaly_floor_usd        = optional(number, 2)
    databricks_workspace_tag = optional(string, "Workspace")
  })
  default = null

  validation {
    condition     = var.cost == null ? true : can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.cost.bucket))
    error_message = "cost.bucket is an S3 bucket name."
  }

  validation {
    condition     = var.cost == null ? true : can(regex("^[^/](.*[^/])?$", var.cost.normalized_prefix))
    error_message = "cost.normalized_prefix has no leading or trailing /."
  }

  validation {
    condition     = var.cost == null ? true : length(var.cost.providers) > 0 && alltrue([for p in var.cost.providers : contains(["aws", "databricks"], p)])
    error_message = "cost.providers is aws, databricks or both."
  }

  validation {
    condition     = var.cost == null ? true : length(var.cost.run_join_tags) > 0
    error_message = "cost.run_join_tags names at least one tag."
  }

  validation {
    condition = var.cost == null ? true : alltrue([
      for usd in concat(var.cost.budgets.total == null ? [] : [var.cost.budgets.total], values(var.cost.budgets.projects), values(var.cost.budgets.accounts)) : usd > 0
    ])
    error_message = "Every cost.budgets amount is a monthly USD amount above 0."
  }

  validation {
    condition     = var.cost == null ? true : var.cost.anomaly_floor_usd >= 0
    error_message = "cost.anomaly_floor_usd is at least 0."
  }

  validation {
    condition     = var.cost == null ? true : can(regex("^[A-Za-z0-9 _.:/=+@-]{1,128}$", var.cost.databricks_workspace_tag))
    error_message = "cost.databricks_workspace_tag is an AWS tag key: 1 to 128 letters, digits, spaces and _ . : / = + @ -."
  }
}
