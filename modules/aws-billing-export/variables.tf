variable "name" {
  description = <<-EOT
    The export's name. AWS delivers under `<prefix>/<name>/`, so changing it
    starts a new delivery folder.
  EOT
  type        = string

  validation {
    condition     = can(regex("^[0-9A-Za-z!_.*'()-]{1,128}$", var.name))
    error_message = "name must be 1 to 128 letters, digits or ! _ . * ' ( ) -, with no spaces or slashes."
  }
}

variable "description" {
  description = "The export's description, shown in the Billing console."
  type        = string
  default     = "FOCUS 1.2 with AWS columns"
}

variable "bucket_name" {
  description = <<-EOT
    The bucket AWS delivers into. Its policy must already let AWS Data Exports put
    objects for this account's exports (`billing-bucket` with this account in
    `aws_export_source_account_ids`), or creating the export fails.
  EOT
  type        = string
}

variable "bucket_owner_account_id" {
  description = <<-EOT
    The 12-digit account that owns `bucket_name`, when it is not the account this
    export is created in (cross-account delivery). Null for a bucket in the same
    account.
  EOT
  type        = string
  default     = null

  validation {
    condition     = var.bucket_owner_account_id == null || can(regex("^[0-9]{12}$", var.bucket_owner_account_id))
    error_message = "bucket_owner_account_id must be a 12-digit account ID, as a string, or null."
  }
}

variable "bucket_region" {
  description = "The bucket's region."
  type        = string
  default     = "us-east-1"
}

variable "prefix" {
  description = <<-EOT
    The key prefix AWS delivers under, with no leading or trailing slash. The
    default is `billing-bucket`'s `aws_export_prefix`.
  EOT
  type        = string
  default     = "raw/provider=aws/source=data-exports"

  validation {
    condition     = length(var.prefix) > 0 && !startswith(var.prefix, "/") && !endswith(var.prefix, "/") && !strcontains(var.prefix, "//")
    error_message = "prefix must be non-empty, with no leading, trailing or doubled slash."
  }
}

variable "time_granularity" {
  description = <<-EOT
    The granularity of the line items: `HOURLY`, `DAILY` or `MONTHLY`. Daily is
    enough for cost dashboards and keeps the files small.
  EOT
  type        = string
  default     = "DAILY"

  validation {
    condition     = contains(["HOURLY", "DAILY", "MONTHLY"], var.time_granularity)
    error_message = "time_granularity must be HOURLY, DAILY or MONTHLY."
  }
}
