# The bucket every billing source delivers into.
#
#   raw/          what each provider delivered, under raw/provider=<p>/source=<s>/;
#                 versioned, never expired, and (protect_raw) never deletable
#   normalized/   the normalizer's output, overwritten in place; its old
#                 versions expire after normalized_noncurrent_days
#
# Object Lock is deliberately not used: its compliance mode cannot be undone,
# even by the account's root. The delete deny can, by an admin changing the
# policy on purpose.

locals {
  arn               = "arn:aws:s3:::${var.bucket_name}"
  aws_export_prefix = "raw/provider=aws/source=data-exports"

  tls_statement = {
    Sid       = "DenyInsecureTransport"
    Effect    = "Deny"
    Principal = "*"
    Action    = "s3:*"
    Resource  = [local.arn, "${local.arn}/*"]
    Condition = { Bool = { "aws:SecureTransport" = "false" } }
  }

  raw_delete_statement = {
    Sid       = "DenyRawDeletes"
    Effect    = "Deny"
    Principal = "*"
    Action    = ["s3:DeleteObject", "s3:DeleteObjectVersion"]
    Resource  = "${local.arn}/raw/*"
  }

  # As AWS documents it for Data Exports: put only, for the listed accounts'
  # exports only. The resource is the whole bucket, as documented; the export
  # itself chooses the prefix.
  delivery_statement = {
    Sid       = "AllowDataExportsDelivery"
    Effect    = "Allow"
    Principal = { Service = "bcm-data-exports.amazonaws.com" }
    Action    = "s3:PutObject"
    Resource  = "${local.arn}/*"
    Condition = {
      ArnLike      = { "aws:SourceArn" = [for id in var.aws_export_source_account_ids : "arn:aws:bcm-data-exports:us-east-1:${id}:export/*"] }
      StringEquals = { "aws:SourceAccount" = var.aws_export_source_account_ids }
    }
  }

  policy = {
    Version = "2012-10-17"
    Statement = concat(
      [local.tls_statement],
      var.protect_raw ? [local.raw_delete_statement] : [],
      length(var.aws_export_source_account_ids) > 0 ? [local.delivery_statement] : [],
    )
  }
}

resource "aws_s3_bucket" "this" {
  bucket = var.bucket_name

  tags = {
    Name      = var.bucket_name
    Component = "billing"
  }

  # Destroying or replacing the bucket (a new bucket_name, or removing the
  # module) is refused at plan. Without this, Terraform would first destroy
  # the policy, versioning, public access block and ownership controls, and
  # only then fail on the non-empty bucket, leaving the data unprotected.
  # To stop managing the bucket on purpose, use a `removed` block with
  # `lifecycle { destroy = false }` (see the README).
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_ownership_controls" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket = aws_s3_bucket.this.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "this" {
  bucket = aws_s3_bucket.this.id

  versioning_configuration {
    status = "Enabled"
  }
}

# SSE-S3: Data Exports writes with it and needs no key grants.
resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  # Aborting an upload that never completed deletes no object.
  rule {
    id     = "abort-incomplete-uploads"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  # Only the normalized layer's replaced versions expire. Nothing under raw/
  # ever does.
  rule {
    id     = "expire-old-normalized-versions"
    status = "Enabled"

    filter {
      prefix = "normalized/"
    }

    noncurrent_version_expiration {
      noncurrent_days = var.normalized_noncurrent_days
    }
  }

  depends_on = [aws_s3_bucket_versioning.this]
}

resource "aws_s3_bucket_policy" "this" {
  bucket = aws_s3_bucket.this.id
  policy = jsonencode(local.policy)

  depends_on = [aws_s3_bucket_public_access_block.this]
}
