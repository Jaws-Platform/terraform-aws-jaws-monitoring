# The normalizer's schedule, with EventBridge Scheduler: one invocation per
# schedule_expression. Runs are idempotent, so a retry or a run by hand at the
# same time only rewrites the same outputs.

resource "aws_iam_role" "scheduler" {
  name        = "${var.name}-scheduler"
  description = "Invokes ${var.name} on its schedule"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "scheduler.amazonaws.com" }
        Action    = "sts:AssumeRole"
        Condition = { StringEquals = { "aws:SourceAccount" = local.account_id } }
      },
    ]
  })

  tags = {
    Name      = "${var.name}-scheduler"
    Component = "billing"
  }
}

resource "aws_iam_role_policy" "scheduler" {
  name = "invoke-the-normalizer"
  role = aws_iam_role.scheduler.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "InvokeTheNormalizer"
      Effect   = "Allow"
      Action   = "lambda:InvokeFunction"
      Resource = local.function_arn
    }]
  })
}

resource "aws_scheduler_schedule" "this" {
  name                = var.name
  description         = "Run ${var.name} (${var.schedule_expression})"
  schedule_expression = var.schedule_expression
  group_name          = "default"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = local.function_arn
    role_arn = aws_iam_role.scheduler.arn
    input    = jsonencode({ source = "schedule" })

    retry_policy {
      maximum_event_age_in_seconds = 900
      maximum_retry_attempts       = 2
    }
  }

  depends_on = [aws_iam_role_policy.scheduler, aws_lambda_function.this]
}
