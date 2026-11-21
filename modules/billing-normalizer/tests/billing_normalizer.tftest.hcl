# The billing normalizer Lambda: Python 3.13 on arm64 with the AWS SDK for
# pandas layer, run hourly, reading only its sources and writing only the
# normalized layer. Mock providers: nothing is called.

mock_provider "aws" {
  override_during = plan

  mock_data "aws_region" {
    defaults = {
      region = "us-east-1"
    }
  }

  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "222222222222"
    }
  }

  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::222222222222:role/acme-billing-normalizer"
    }
  }
}

mock_provider "archive" {}

variables {
  name        = "acme-billing-normalizer"
  bucket_name = "acme-billing"
  aws = {
    delivery_prefix = "raw/provider=aws/source=data-exports/acme-focus-daily"
  }
  databricks = {}
  runs = {
    prefixes  = ["raw/provider=acme/source=task-runs"]
    join_tags = ["RunId", "TaskId"]
  }
}

run "function_is_python_3_13_on_arm64_with_the_pandas_layer" {
  command = plan

  assert {
    condition     = aws_lambda_function.this.runtime == "python3.13" && aws_lambda_function.this.architectures == tolist(["arm64"]) && aws_lambda_function.this.handler == "normalizer.handler.handler"
    error_message = "Python 3.13 on arm64, entered at normalizer.handler.handler"
  }

  assert {
    condition     = aws_lambda_function.this.timeout == 900 && aws_lambda_function.this.memory_size == 1024
    error_message = "15 minutes and 1 GB"
  }

  assert {
    condition     = aws_lambda_function.this.layers == tolist(["arn:aws:lambda:us-east-1:336392948345:layer:AWSSDKPandas-Python313-Arm64:17"])
    error_message = "pyarrow comes from the AWS SDK for pandas layer for Python 3.13 on arm64, in the function's region"
  }

  assert {
    condition     = aws_lambda_function.this.tags == tomap({ Name = "acme-billing-normalizer", Component = "billing" })
    error_message = "the module sets Name and Component only"
  }
}

run "config_renders_every_enabled_provider" {
  command = plan

  assert {
    condition = jsondecode(aws_lambda_function.this.environment[0].variables.NORMALIZER_CONFIG) == {
      bucket            = "acme-billing"
      normalized_prefix = "normalized"
      promoted_tags     = ["Project", "Component", "Environment"]
      aws = {
        delivery_prefix    = "raw/provider=aws/source=data-exports/acme-focus-daily"
        exclude_publishers = []
      }
      databricks = {
        prefix             = "raw/provider=databricks/source=system-tables"
        account_name       = "Databricks"
        workspace_names    = {}
        workspace_projects = {}
      }
      runs = {
        prefixes  = ["raw/provider=acme/source=task-runs"]
        join_tags = ["RunId", "TaskId"]
      }
    }
    error_message = "the rendered config is the JSON normalizer.config.load_config reads, with the defaults applied"
  }
}

run "role_reads_the_sources_and_writes_only_normalized" {
  command = plan

  assert {
    condition = jsondecode(aws_iam_role_policy.this.policy).Statement == [
      {
        Sid      = "ListTheBucket"
        Effect   = "Allow"
        Action   = "s3:ListBucket"
        Resource = "arn:aws:s3:::acme-billing"
      },
      {
        Sid    = "ReadTheSources"
        Effect = "Allow"
        Action = "s3:GetObject"
        Resource = [
          "arn:aws:s3:::acme-billing/raw/provider=aws/source=data-exports/acme-focus-daily/*",
          "arn:aws:s3:::acme-billing/raw/provider=databricks/source=system-tables/*",
          "arn:aws:s3:::acme-billing/raw/provider=acme/source=task-runs/*",
          "arn:aws:s3:::acme-billing/normalized/*",
        ]
      },
      {
        Sid      = "WriteTheNormalizedLayer"
        Effect   = "Allow"
        Action   = "s3:PutObject"
        Resource = "arn:aws:s3:::acme-billing/normalized/*"
      },
      {
        Sid      = "WriteLogs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:us-east-1:222222222222:log-group:/aws/lambda/acme-billing-normalizer:*"
      },
    ]
    error_message = "the normalizer lists the bucket, reads only its sources and its own layer, and writes only normalized/"
  }
}

run "disabled_providers_leave_no_trace" {
  command = plan

  variables {
    databricks = null
    runs       = null
  }

  assert {
    condition     = jsondecode(aws_lambda_function.this.environment[0].variables.NORMALIZER_CONFIG).databricks == null && jsondecode(aws_lambda_function.this.environment[0].variables.NORMALIZER_CONFIG).runs == null
    error_message = "a disabled provider is null in the config"
  }

  assert {
    condition = one([for s in jsondecode(aws_iam_role_policy.this.policy).Statement : s.Resource if s.Sid == "ReadTheSources"]) == [
      "arn:aws:s3:::acme-billing/raw/provider=aws/source=data-exports/acme-focus-daily/*",
      "arn:aws:s3:::acme-billing/normalized/*",
    ]
    error_message = "the role reads only the enabled sources"
  }
}

run "runs_hourly_through_the_scheduler" {
  command = plan

  assert {
    condition     = aws_scheduler_schedule.this.schedule_expression == "rate(1 hour)" && aws_scheduler_schedule.this.target[0].arn == "arn:aws:lambda:us-east-1:222222222222:function:acme-billing-normalizer"
    error_message = "EventBridge Scheduler invokes the function every hour"
  }

  assert {
    condition = jsondecode(aws_iam_role_policy.scheduler.policy).Statement == [{
      Sid      = "InvokeTheNormalizer"
      Effect   = "Allow"
      Action   = "lambda:InvokeFunction"
      Resource = "arn:aws:lambda:us-east-1:222222222222:function:acme-billing-normalizer"
    }]
    error_message = "the scheduler may only invoke this function"
  }
}

run "logs_are_kept_30_days" {
  command = plan

  assert {
    condition     = aws_cloudwatch_log_group.this.name == "/aws/lambda/acme-billing-normalizer" && aws_cloudwatch_log_group.this.retention_in_days == 30
    error_message = "the function's log group is kept 30 days"
  }
}

run "a_custom_layer_replaces_the_default" {
  command = plan

  variables {
    pandas_layer_arn = "arn:aws:lambda:us-east-1:123456789012:layer:my-pyarrow:3"
  }

  assert {
    condition     = aws_lambda_function.this.layers == tolist(["arn:aws:lambda:us-east-1:123456789012:layer:my-pyarrow:3"])
    error_message = "pandas_layer_arn replaces the default layer"
  }
}

run "needs_at_least_one_source" {
  command = plan

  variables {
    aws        = null
    databricks = null
    runs       = null
  }

  expect_failures = [aws_lambda_function.this]
}

run "rejects_runs_without_join_tags" {
  command = plan

  variables {
    runs = {
      prefixes  = ["raw/provider=acme/source=task-runs"]
      join_tags = []
    }
  }

  expect_failures = [var.runs]
}

run "rejects_prefixes_with_stray_slashes" {
  command = plan

  variables {
    normalized_prefix = "normalized/"
  }

  expect_failures = [var.normalized_prefix]
}
