# The function's role: list the bucket, read the enabled sources and the
# normalized layer, write only the normalized layer, write its own logs.
#
# ListBucket is bucket-wide: S3 answers a request for a missing object with 403
# instead of 404 unless the caller may list the bucket, and the normalizer looks
# up outputs that do not exist yet.

locals {
  bucket_arn = "arn:aws:s3:::${var.bucket_name}"

  policy = {
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ListTheBucket"
        Effect   = "Allow"
        Action   = "s3:ListBucket"
        Resource = local.bucket_arn
      },
      {
        Sid      = "ReadTheSources"
        Effect   = "Allow"
        Action   = "s3:GetObject"
        Resource = [for prefix in concat(local.source_prefixes, [var.normalized_prefix]) : "${local.bucket_arn}/${prefix}/*"]
      },
      {
        Sid      = "WriteTheNormalizedLayer"
        Effect   = "Allow"
        Action   = "s3:PutObject"
        Resource = "${local.bucket_arn}/${var.normalized_prefix}/*"
      },
      {
        Sid      = "WriteLogs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:${local.region}:${local.account_id}:log-group:${local.log_group_name}:*"
      },
    ]
  }
}

resource "aws_iam_role" "this" {
  name        = var.name
  description = "Runs ${var.name}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "lambda.amazonaws.com" }
        Action    = "sts:AssumeRole"
      },
    ]
  })

  tags = {
    Name      = var.name
    Component = "billing"
  }
}

resource "aws_iam_role_policy" "this" {
  name   = "normalize-billing"
  role   = aws_iam_role.this.id
  policy = jsonencode(local.policy)
}
