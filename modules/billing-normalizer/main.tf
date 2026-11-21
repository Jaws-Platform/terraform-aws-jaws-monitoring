# The billing normalizer: a Lambda that runs files/normalizer on a schedule.
#
#   reads    every enabled source's newest delivery under raw/ (and task-run
#            event records)
#   writes   <normalized_prefix>/schema=focus-1.2/provider=<p>/billing_period=YYYY-MM/data.parquet
#            <normalized_prefix>/schema=runs-1/event_month=YYYY-MM/data.parquet
#            <normalized_prefix>/_runs/<time>.json and _runs/latest.json
#
# An output is rebuilt only when its sources change; pyarrow comes from the AWS
# SDK for pandas layer, so the package itself is plain Python.

data "aws_region" "current" {}

data "aws_caller_identity" "current" {}

locals {
  region     = data.aws_region.current.region
  account_id = data.aws_caller_identity.current.account_id

  function_arn   = "arn:aws:lambda:${local.region}:${local.account_id}:function:${var.name}"
  log_group_name = "/aws/lambda/${var.name}"

  pandas_layer_arn = coalesce(var.pandas_layer_arn, "arn:aws:lambda:${local.region}:336392948345:layer:AWSSDKPandas-Python313-Arm64:17")

  config = {
    bucket            = var.bucket_name
    normalized_prefix = var.normalized_prefix
    promoted_tags     = var.promoted_tags
    aws = var.aws == null ? null : {
      delivery_prefix    = var.aws.delivery_prefix
      exclude_publishers = var.aws.exclude_publishers
    }
    databricks = var.databricks == null ? null : {
      prefix             = var.databricks.prefix
      account_name       = var.databricks.account_name
      workspace_names    = var.databricks.workspace_names
      workspace_projects = var.databricks.workspace_projects
    }
    runs = var.runs == null ? null : {
      prefixes  = var.runs.prefixes
      join_tags = var.runs.join_tags
    }
  }

  source_prefixes = concat(
    var.aws == null ? [] : [var.aws.delivery_prefix],
    var.databricks == null ? [] : [var.databricks.prefix],
    var.runs == null ? [] : var.runs.prefixes,
  )
}

data "archive_file" "code" {
  type        = "zip"
  source_dir  = "${path.module}/files"
  output_path = "${path.module}/.build/normalizer.zip"
  excludes    = ["test_*.py", "fakes.py", "requirements-test.txt", "**/__pycache__/**", "__pycache__/**"]
}

resource "aws_cloudwatch_log_group" "this" {
  name              = local.log_group_name
  retention_in_days = var.log_retention_days

  tags = {
    Name      = local.log_group_name
    Component = "billing"
  }
}

resource "aws_lambda_function" "this" {
  function_name = var.name
  description   = "Normalizes billing deliveries in ${var.bucket_name} to FOCUS-aligned Parquet"
  role          = aws_iam_role.this.arn

  runtime       = "python3.13"
  architectures = ["arm64"]
  handler       = "normalizer.handler.handler"
  layers        = [local.pandas_layer_arn]
  timeout       = 900
  memory_size   = 1024

  filename         = data.archive_file.code.output_path
  source_code_hash = data.archive_file.code.output_base64sha256

  environment {
    variables = {
      NORMALIZER_CONFIG = jsonencode(local.config)
    }
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.this.name
  }

  tags = {
    Name      = var.name
    Component = "billing"
  }

  lifecycle {
    precondition {
      condition     = var.aws != null || var.databricks != null || var.runs != null
      error_message = "Enable at least one source: aws, databricks or runs."
    }
  }

  depends_on = [aws_iam_role_policy.this, aws_cloudwatch_log_group.this]
}
