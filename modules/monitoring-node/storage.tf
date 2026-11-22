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

resource "aws_iam_role" "snapshots" {
  count = var.snapshots.enabled ? 1 : 0

  name        = "${var.name}-snapshots"
  description = "Data Lifecycle Manager: snapshots of ${local.data_volume_name}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "dlm.amazonaws.com" }
        Action    = "sts:AssumeRole"
      },
    ]
  })

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "snapshots" {
  count = var.snapshots.enabled ? 1 : 0

  role       = aws_iam_role.snapshots[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSDataLifecycleManagerServiceRole"
}

resource "aws_dlm_lifecycle_policy" "snapshots" {
  count = var.snapshots.enabled ? 1 : 0

  description        = "Daily snapshots of ${local.data_volume_name}"
  execution_role_arn = aws_iam_role.snapshots[0].arn
  state              = "ENABLED"

  policy_details {
    resource_types = ["VOLUME"]
    target_tags    = { Name = local.data_volume_name }

    schedule {
      name      = "daily"
      copy_tags = true

      create_rule {
        interval      = 24
        interval_unit = "HOURS"
        times         = [var.snapshots.time_utc]
      }

      retain_rule {
        count = var.snapshots.keep
      }
    }
  }

  tags = local.tags
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
