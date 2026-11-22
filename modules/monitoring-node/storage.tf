# The data volume, its optional snapshots, and the config bucket.

resource "aws_ebs_volume" "data" {
  availability_zone = data.aws_subnet.this.availability_zone
  size              = var.data_volume_gb
  type              = "gp3"
  encrypted         = true

  tags = merge(local.tags, { Name = local.data_volume_name })
}

resource "aws_volume_attachment" "data" {
  device_name                    = "/dev/sdf"
  volume_id                      = aws_ebs_volume.data.id
  instance_id                    = aws_instance.this.id
  stop_instance_before_detaching = true
}

# ------------------------------------------------------------- snapshots
# AWS Backup, not Data Lifecycle Manager: a backup plan takes a time zone, so
# with a schedule the snapshot lands in the off window all year (6.10), after a
# clean shutdown. DLM takes only UTC times, and Terraform can't convert one.
# Without a schedule it runs at time_utc. The vault refuses to be destroyed
# while it holds recovery points, so a stray destroy never deletes the backups.

locals {
  snapshot_after_stop = local.scheduled ? (local.schedule_off_hour + 1) % 24 : null
  # 01:00-02:59 is when daylight saving changes: a run there can be skipped.
  snapshot_hour     = local.scheduled ? (local.snapshot_after_stop >= 1 && local.snapshot_after_stop < 3 ? 3 : local.snapshot_after_stop) : tonumber(split(":", var.snapshots.time_utc)[0])
  snapshot_minute   = local.scheduled ? 0 : tonumber(split(":", var.snapshots.time_utc)[1])
  snapshot_timezone = local.scheduled ? var.schedule.timezone : "Etc/UTC"
}

resource "aws_iam_role" "snapshots" {
  count = var.snapshots.enabled ? 1 : 0

  name        = "${var.name}-snapshots"
  description = "AWS Backup: daily snapshots of ${local.data_volume_name}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "backup.amazonaws.com" }
        Action    = "sts:AssumeRole"
      },
    ]
  })

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "snapshots" {
  count = var.snapshots.enabled ? 1 : 0

  role       = aws_iam_role.snapshots[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
}

resource "aws_backup_vault" "snapshots" {
  count = var.snapshots.enabled ? 1 : 0

  name          = "${var.name}-snapshots"
  force_destroy = false

  tags = local.tags
}

resource "aws_backup_plan" "snapshots" {
  count = var.snapshots.enabled ? 1 : 0

  name = "${var.name}-snapshots"

  rule {
    rule_name                    = "daily"
    target_vault_name            = aws_backup_vault.snapshots[0].name
    schedule                     = "cron(${local.snapshot_minute} ${local.snapshot_hour} ? * * *)"
    schedule_expression_timezone = local.snapshot_timezone
    start_window                 = 60
    completion_window            = 180

    lifecycle {
      delete_after = var.snapshots.keep
    }
  }

  tags = local.tags
}

resource "aws_backup_selection" "snapshots" {
  count = var.snapshots.enabled ? 1 : 0

  name         = "${var.name}-data"
  plan_id      = aws_backup_plan.snapshots[0].id
  iam_role_arn = aws_iam_role.snapshots[0].arn
  resources    = [aws_ebs_volume.data.arn]
}

# ---------------------------------------------------------- config bucket

resource "aws_s3_bucket" "config" {
  bucket = local.config_bucket

  tags = merge(local.tags, { Name = local.config_bucket })
}

resource "aws_s3_bucket_ownership_controls" "config" {
  bucket = aws_s3_bucket.config.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "config" {
  bucket = aws_s3_bucket.config.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "config" {
  bucket = aws_s3_bucket.config.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "config" {
  bucket = aws_s3_bucket.config.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "config" {
  bucket = aws_s3_bucket.config.id

  rule {
    id     = "expire-old-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 30
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.config]
}

# The bundle, named by its content: a new key for every change, so the node can
# tell a new bundle from the one it runs.
resource "aws_s3_object" "bundle" {
  bucket       = aws_s3_bucket.config.id
  key          = "bundles/${sha256(local.bundle_json)}.json"
  content      = local.bundle_json
  content_type = "application/json"

  tags = local.tags
}
