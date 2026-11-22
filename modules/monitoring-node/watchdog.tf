# The watchdog (6.9), outside the node so a dead node still gets reported. On
# whenever Slack is: two status-check alarms recover or reboot the instance and
# tell an SNS topic; the watchdog Lambda (files/watchdog/) runs from that topic
# and every 5 minutes, judges the node against its schedule, and posts to the
# host channel's webhook. Its state is one SSM parameter.

locals {
  watched          = var.slack != null
  watchdog_name    = "${var.name}-watchdog"
  watchdog_state   = "${local.parameter_prefix}/watchdog-state"
  watchdog_webhook = local.watched ? var.slack.channels[var.slack.routes.host] : null
  watchdog_alarms  = ["${var.name}-system-status", "${var.name}-instance-status"]
  # Built from names, so the role's policy is known at plan.
  watchdog_alarm_arns = [for a in local.watchdog_alarms : "arn:aws:cloudwatch:${local.region}:${local.account_id}:alarm:${a}"]
  watchdog_log_arn    = "arn:aws:logs:${local.region}:${local.account_id}:log-group:/aws/lambda/${local.watchdog_name}"
}

resource "aws_sns_topic" "watchdog" {
  count = local.watched ? 1 : 0

  name = local.watchdog_name
  tags = local.tags
}

resource "aws_cloudwatch_metric_alarm" "system_status" {
  count = local.watched ? 1 : 0

  alarm_name          = local.watchdog_alarms[0]
  alarm_description   = "${var.name}: the EC2 system status check failed; EC2 recovers the instance onto other hardware."
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed_System"
  dimensions          = { InstanceId = aws_instance.this.id }
  statistic           = "Maximum"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1
  period              = 60
  evaluation_periods  = 2
  treat_missing_data  = "notBreaching" # a scheduled stop sends no data: silent
  alarm_actions       = ["arn:aws:automate:${local.region}:ec2:recover", aws_sns_topic.watchdog[0].arn]
  ok_actions          = [aws_sns_topic.watchdog[0].arn]
  tags                = local.tags
}

resource "aws_cloudwatch_metric_alarm" "instance_status" {
  count = local.watched ? 1 : 0

  alarm_name          = local.watchdog_alarms[1]
  alarm_description   = "${var.name}: the EC2 instance status check failed; EC2 reboots the instance."
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed_Instance"
  dimensions          = { InstanceId = aws_instance.this.id }
  statistic           = "Maximum"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1
  period              = 60
  evaluation_periods  = 2
  treat_missing_data  = "notBreaching"
  alarm_actions       = ["arn:aws:automate:${local.region}:ec2:reboot", aws_sns_topic.watchdog[0].arn]
  ok_actions          = [aws_sns_topic.watchdog[0].arn]
  tags                = local.tags
}

# ----------------------------------------------------------------- the Lambda

data "archive_file" "watchdog" {
  count = local.watched ? 1 : 0

  type        = "zip"
  source_dir  = "${path.module}/files/watchdog"
  output_path = "${path.module}/.build/watchdog.zip"
}

resource "aws_cloudwatch_log_group" "watchdog" {
  count = local.watched ? 1 : 0

  name              = "/aws/lambda/${local.watchdog_name}"
  retention_in_days = 30
  tags              = local.tags
}

resource "aws_iam_role" "watchdog" {
  count = local.watched ? 1 : 0

  name        = local.watchdog_name
  description = "The watchdog Lambda for ${var.name}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = local.tags
}

resource "aws_iam_role_policy" "watchdog" {
  count = local.watched ? 1 : 0

  name = "watchdog"
  role = aws_iam_role.watchdog[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = "ec2:DescribeInstances", Resource = "*" }, # Describe* takes no resource
      { Effect = "Allow", Action = "cloudwatch:DescribeAlarms", Resource = local.watchdog_alarm_arns },
      { Effect = "Allow", Action = "ssm:GetParameter", Resource = ["${local.parameter_arn}${local.watchdog_webhook}", "${local.parameter_arn}${local.watchdog_state}"] },
      { Effect = "Allow", Action = "ssm:PutParameter", Resource = "${local.parameter_arn}${local.watchdog_state}" },
      { Effect = "Allow", Action = ["logs:CreateLogStream", "logs:PutLogEvents"], Resource = "${local.watchdog_log_arn}:*" },
    ]
  })
}

resource "aws_lambda_function" "watchdog" {
  count = local.watched ? 1 : 0

  function_name    = local.watchdog_name
  description      = "Posts to Slack when ${var.name} is down, on off-hours, or not answering"
  role             = aws_iam_role.watchdog[0].arn
  runtime          = "python3.13"
  handler          = "watchdog.handler"
  architectures    = ["arm64"]
  memory_size      = 128
  timeout          = 30
  filename         = data.archive_file.watchdog[0].output_path
  source_code_hash = data.archive_file.watchdog[0].output_base64sha256

  environment {
    variables = {
      NAME              = var.name
      INSTANCE_ID       = aws_instance.this.id
      SCHEDULE          = local.schedule_json
      DOMAIN            = var.domain == null ? "" : var.domain
      WEBHOOK_PARAMETER = local.watchdog_webhook
      STATE_PARAMETER   = local.watchdog_state
      ALARMS            = join(",", local.watchdog_alarms)
    }
  }

  depends_on = [aws_cloudwatch_log_group.watchdog]
  tags       = local.tags
}

resource "aws_sns_topic_subscription" "watchdog" {
  count = local.watched ? 1 : 0

  topic_arn = aws_sns_topic.watchdog[0].arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.watchdog[0].arn
}

resource "aws_lambda_permission" "watchdog_sns" {
  count = local.watched ? 1 : 0

  statement_id  = "sns"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.watchdog[0].function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.watchdog[0].arn
}

# ------------------------------------------------------- every 5 minutes

resource "aws_iam_role" "watchdog_schedule" {
  count = local.watched ? 1 : 0

  name        = "${local.watchdog_name}-schedule"
  description = "EventBridge Scheduler: run the watchdog for ${var.name} every 5 minutes"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "scheduler.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = { StringEquals = { "aws:SourceAccount" = local.account_id } }
    }]
  })
  tags = local.tags
}

resource "aws_iam_role_policy" "watchdog_schedule" {
  count = local.watched ? 1 : 0

  name = "invoke"
  role = aws_iam_role.watchdog_schedule[0].id
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "lambda:InvokeFunction", Resource = aws_lambda_function.watchdog[0].arn }]
  })
}

resource "aws_scheduler_schedule" "watchdog" {
  count = local.watched ? 1 : 0

  name                = local.watchdog_name
  description         = "Run the watchdog for ${var.name}"
  schedule_expression = "rate(5 minutes)"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.watchdog[0].arn
    role_arn = aws_iam_role.watchdog_schedule[0].arn
  }
}
