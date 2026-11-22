variable "name" {
  description = "The function's name; also names its role, log group, scheduler role and schedule."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9_-]{1,64}$", var.name))
    error_message = "name must be 1 to 64 letters, digits, hyphens or underscores."
  }
}

variable "bucket_name" {
  description = "The billing bucket (`billing-bucket`) the sources deliver into and the normalized layer is written to."
  type        = string
}

variable "normalized_prefix" {
  description = "Where the normalized layer is written: `billing-bucket`'s `normalized_prefix`. No leading or trailing slash."
  type        = string
  nullable    = false
  default     = "normalized"

  validation {
    condition     = length(var.normalized_prefix) > 0 && !startswith(var.normalized_prefix, "/") && !endswith(var.normalized_prefix, "/") && !strcontains(var.normalized_prefix, "//")
    error_message = "normalized_prefix must be non-empty, with no leading, trailing or doubled slash."
  }
}

variable "promoted_tags" {
  description = <<-EOT
    Tags promoted out of each row's tag map into their own `x_<tag>` columns, for
    grouping. A tag key is matched as written, as `user:<tag>` or as
    `user_<tag lowercased>`. Changing the list rebuilds every output.
  EOT
  type        = list(string)
  nullable    = false
  default     = ["Project", "Component", "Environment"]

  validation {
    condition     = alltrue([for tag in var.promoted_tags : can(regex("^[A-Za-z][A-Za-z0-9_]*$", tag))]) && length(distinct(var.promoted_tags)) == length(var.promoted_tags)
    error_message = "promoted_tags must be distinct names of letters, digits and underscores, starting with a letter."
  }
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

  validation {
    condition     = var.aws == null || (length(try(var.aws.delivery_prefix, "")) > 0 && !startswith(try(var.aws.delivery_prefix, ""), "/") && !endswith(try(var.aws.delivery_prefix, ""), "/") && !strcontains(try(var.aws.delivery_prefix, ""), "//"))
    error_message = "aws.delivery_prefix must be non-empty, with no leading, trailing or doubled slash."
  }
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

  validation {
    condition     = var.databricks == null || (length(try(var.databricks.prefix, "")) > 0 && !startswith(try(var.databricks.prefix, ""), "/") && !endswith(try(var.databricks.prefix, ""), "/") && !strcontains(try(var.databricks.prefix, ""), "//"))
    error_message = "databricks.prefix must be non-empty, with no leading, trailing or doubled slash."
  }
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

  validation {
    condition     = var.runs == null || length(try(var.runs.join_tags, [])) > 0
    error_message = "runs.join_tags must name at least one tag."
  }

  validation {
    condition     = var.runs == null || (length(try(var.runs.prefixes, [])) > 0 && alltrue([for p in try(var.runs.prefixes, []) : length(p) > 0 && !startswith(p, "/") && !endswith(p, "/") && !strcontains(p, "//")]))
    error_message = "runs.prefixes must be non-empty prefixes with no leading, trailing or doubled slash."
  }
}

variable "schedule_expression" {
  description = "How often the normalizer runs, as an EventBridge Scheduler expression. A run with nothing new to read only writes its run record."
  type        = string
  nullable    = false
  default     = "rate(1 hour)"
}

variable "pandas_layer_arn" {
  description = <<-EOT
    The Lambda layer that provides pyarrow. Null uses the AWS SDK for pandas layer
    for Python 3.13 on arm64 in the function's region (awswrangler 3.18.0).
  EOT
  type        = string
  default     = null
}

variable "memory_size" {
  description = <<-EOT
    The function's memory, in MB. A month of AWS line items takes roughly 6 KB per
    row at peak; raise it when a billing period reaches about 150,000 rows.
  EOT
  type        = number
  nullable    = false
  default     = 1024

  validation {
    condition     = var.memory_size >= 128 && var.memory_size <= 10240 && var.memory_size == floor(var.memory_size)
    error_message = "memory_size must be a whole number of MB from 128 to 10240."
  }
}

variable "log_retention_days" {
  description = "Retention of the function's CloudWatch log group, in days."
  type        = number
  nullable    = false
  default     = 30

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.log_retention_days)
    error_message = "log_retention_days must be one of the retention periods CloudWatch Logs accepts."
  }
}
