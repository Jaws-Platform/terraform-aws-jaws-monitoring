variable "bucket_name" {
  description = <<-EOT
    The bucket's name. Every billing source delivers under `raw/` and the
    normalizer writes under `normalized/` (see the README). Choose it before the
    first export is created: the export and the policies name it, and AWS stops
    delivering if the bucket changes.
  EOT
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.bucket_name)) && !strcontains(var.bucket_name, "..")
    error_message = "bucket_name must be a valid S3 bucket name: 3 to 63 lowercase letters, digits, dots and hyphens, starting and ending with a letter or digit."
  }
}

variable "aws_export_source_account_ids" {
  description = <<-EOT
    The AWS accounts whose Data Exports may deliver into this bucket, as 12-digit
    strings: the payer (management) account for organization-wide data, or any
    account that exports its own bill. AWS Data Exports may then put objects for
    those accounts' exports only. Empty: no export can deliver.
  EOT
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for id in var.aws_export_source_account_ids : can(regex("^[0-9]{12}$", id))])
    error_message = "aws_export_source_account_ids must be 12-digit account IDs, as strings."
  }
}

variable "protect_raw" {
  description = <<-EOT
    Deny the delete calls (`s3:DeleteObject`, `s3:DeleteObjectVersion`) on
    anything under `raw/`, to every principal, so a delivered bill cannot be
    deleted. Switch it on once the first deliveries have been checked to land
    under the right prefixes: until then a misplaced first object can still be
    cleaned up. The bucket itself always refuses destroy and replacement,
    whatever this is set to.
  EOT
  type        = bool
  default     = true
}

variable "normalized_noncurrent_days" {
  description = <<-EOT
    Days a replaced version of a `normalized/` object is kept before it expires.
    The normalized layer is rebuilt from `raw/` and overwritten in place, so its
    old versions are only an undo window. Raw data never expires.
  EOT
  type        = number
  default     = 30

  validation {
    condition     = var.normalized_noncurrent_days >= 1 && var.normalized_noncurrent_days == floor(var.normalized_noncurrent_days)
    error_message = "normalized_noncurrent_days must be a whole number of days, at least 1."
  }
}
