# The billing bucket: raw deliveries can never be deleted, only the normalized
# layer's old versions expire, and Data Exports may deliver only for the listed
# accounts. Mock provider: nothing is called.

mock_provider "aws" {}

variables {
  bucket_name = "acme-billing"
}

run "defaults_protect_raw_and_require_tls" {
  command = plan

  assert {
    condition     = [for s in jsondecode(aws_s3_bucket_policy.this.policy).Statement : s.Sid] == ["DenyInsecureTransport", "DenyRawDeletes"]
    error_message = "with no export accounts the policy is the TLS deny and the raw/ delete deny, and no Allow"
  }

  assert {
    condition = one([for s in jsondecode(aws_s3_bucket_policy.this.policy).Statement : s if s.Sid == "DenyInsecureTransport"]) == {
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = ["arn:aws:s3:::acme-billing", "arn:aws:s3:::acme-billing/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }
    error_message = "requests without TLS are denied"
  }

  assert {
    condition = one([for s in jsondecode(aws_s3_bucket_policy.this.policy).Statement : s if s.Sid == "DenyRawDeletes"]) == {
      Sid       = "DenyRawDeletes"
      Effect    = "Deny"
      Principal = "*"
      Action    = ["s3:DeleteObject", "s3:DeleteObjectVersion"]
      Resource  = "arn:aws:s3:::acme-billing/raw/*"
    }
    error_message = "nobody may delete an object or a version under raw/"
  }
}

run "export_accounts_may_put_objects_from_their_own_exports" {
  command = plan

  variables {
    aws_export_source_account_ids = ["111111111111", "222222222222"]
  }

  assert {
    condition = one([for s in jsondecode(aws_s3_bucket_policy.this.policy).Statement : s if s.Sid == "AllowDataExportsDelivery"]) == {
      Sid       = "AllowDataExportsDelivery"
      Effect    = "Allow"
      Principal = { Service = "bcm-data-exports.amazonaws.com" }
      Action    = "s3:PutObject"
      Resource  = "arn:aws:s3:::acme-billing/*"
      Condition = {
        ArnLike = { "aws:SourceArn" = [
          "arn:aws:bcm-data-exports:us-east-1:111111111111:export/*",
          "arn:aws:bcm-data-exports:us-east-1:222222222222:export/*",
        ] }
        StringEquals = { "aws:SourceAccount" = ["111111111111", "222222222222"] }
      }
    }
    error_message = "Data Exports may put objects, and only for exports of the listed accounts"
  }
}

run "protect_raw_off_keeps_tls_and_delivery" {
  command = plan

  variables {
    aws_export_source_account_ids = ["111111111111"]
    protect_raw                   = false
  }

  assert {
    condition     = [for s in jsondecode(aws_s3_bucket_policy.this.policy).Statement : s.Sid] == ["DenyInsecureTransport", "AllowDataExportsDelivery"]
    error_message = "turning protect_raw off removes only the delete deny"
  }
}

run "versioned_encrypted_owner_enforced_and_private" {
  command = plan

  assert {
    condition     = aws_s3_bucket_versioning.this.versioning_configuration[0].status == "Enabled"
    error_message = "versioning is on, so an overwrite never loses the older version"
  }

  assert {
    condition     = one(aws_s3_bucket_server_side_encryption_configuration.this.rule).apply_server_side_encryption_by_default[0].sse_algorithm == "AES256"
    error_message = "objects are encrypted with SSE-S3 (Data Exports does not support a KMS key here without extra grants)"
  }

  assert {
    condition     = aws_s3_bucket_ownership_controls.this.rule[0].object_ownership == "BucketOwnerEnforced"
    error_message = "ACLs are disabled"
  }

  assert {
    condition = alltrue([
      aws_s3_bucket_public_access_block.this.block_public_acls,
      aws_s3_bucket_public_access_block.this.block_public_policy,
      aws_s3_bucket_public_access_block.this.ignore_public_acls,
      aws_s3_bucket_public_access_block.this.restrict_public_buckets,
    ])
    error_message = "the bucket can never be public"
  }
}

run "only_normalized_versions_expire" {
  command = plan

  assert {
    condition     = [for r in aws_s3_bucket_lifecycle_configuration.this.rule : r.id] == ["abort-incomplete-uploads", "expire-old-normalized-versions"]
    error_message = "two lifecycle rules, and none for raw/"
  }

  assert {
    condition     = one([for r in aws_s3_bucket_lifecycle_configuration.this.rule : r if r.id == "expire-old-normalized-versions"]).filter[0].prefix == "normalized/" && one([for r in aws_s3_bucket_lifecycle_configuration.this.rule : r if r.id == "expire-old-normalized-versions"]).noncurrent_version_expiration[0].noncurrent_days == 30
    error_message = "noncurrent versions under normalized/ expire after 30 days"
  }

  assert {
    condition     = alltrue([for r in aws_s3_bucket_lifecycle_configuration.this.rule : length(r.expiration) == 0]) && length(one([for r in aws_s3_bucket_lifecycle_configuration.this.rule : r if r.id == "abort-incomplete-uploads"]).noncurrent_version_expiration) == 0
    error_message = "no rule ever expires a current object, and the bucket-wide rule only aborts uploads"
  }

  assert {
    condition     = one([for r in aws_s3_bucket_lifecycle_configuration.this.rule : r if r.id == "abort-incomplete-uploads"]).abort_incomplete_multipart_upload[0].days_after_initiation == 7
    error_message = "incomplete multipart uploads are aborted after 7 days"
  }
}

run "normalized_retention_is_an_input" {
  command = plan

  variables {
    normalized_noncurrent_days = 7
  }

  assert {
    condition     = one([for r in aws_s3_bucket_lifecycle_configuration.this.rule : r if r.id == "expire-old-normalized-versions"]).noncurrent_version_expiration[0].noncurrent_days == 7
    error_message = "normalized_noncurrent_days sets the retention of old normalized versions"
  }
}

run "tags_and_outputs" {
  command = plan

  assert {
    condition     = aws_s3_bucket.this.tags == tomap({ Name = "acme-billing", Component = "billing" })
    error_message = "the module sets Name and Component only; everything else comes from default_tags"
  }

  assert {
    condition     = output.name == "acme-billing" && output.arn == "arn:aws:s3:::acme-billing"
    error_message = "name and ARN are known at plan"
  }

  assert {
    condition     = output.raw_prefix == "raw" && output.aws_export_prefix == "raw/provider=aws/source=data-exports" && output.normalized_prefix == "normalized"
    error_message = "the prefixes are the layout contract"
  }
}

run "rejects_malformed_export_account_ids" {
  command = plan

  variables {
    aws_export_source_account_ids = ["12345"]
  }

  expect_failures = [var.aws_export_source_account_ids]
}

run "rejects_invalid_bucket_names" {
  command = plan

  variables {
    bucket_name = "Acme_Billing"
  }

  expect_failures = [var.bucket_name]
}

run "rejects_a_zero_retention" {
  command = plan

  variables {
    normalized_noncurrent_days = 0
  }

  expect_failures = [var.normalized_noncurrent_days]
}
