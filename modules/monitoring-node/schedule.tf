# The optional off-hours schedule (6.10): two EventBridge Scheduler schedules,
# in the schedule's time zone, call ec2:StartInstances and ec2:StopInstances on
# this one instance. A stop is a normal shutdown, so the compose services stop
# cleanly under systemd. With no schedule the node runs all day.

locals {
  scheduled = var.schedule != null
  week      = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]

  # Whole hours; an off of 24 (midnight at the end of the day) stays 24 here.
  schedule_on_hour  = local.scheduled ? tonumber(substr(var.schedule.on, 0, 2)) : null
  schedule_off_hour = local.scheduled ? tonumber(substr(var.schedule.off, 0, 2)) : null
  schedule_json     = local.scheduled ? jsonencode(var.schedule) : ""

  # A 24:00 stop fires at 00:00 on the next weekday, so its days shift by one.
  schedule_start_days = local.scheduled ? [for d in local.week : upper(d) if contains(var.schedule.days, d)] : []
  schedule_stop_days = !local.scheduled ? [] : local.schedule_off_hour == 24 ? [
    for d in local.week : upper(local.week[(index(local.week, d) + 1) % 7]) if contains(var.schedule.days, d)
  ] : local.schedule_start_days

  schedule_cron = local.scheduled ? {
    start = "cron(0 ${local.schedule_on_hour} ? * ${join(",", local.schedule_start_days)} *)"
    stop  = "cron(0 ${local.schedule_off_hour % 24} ? * ${join(",", local.schedule_stop_days)} *)"
  } : {}
}

resource "aws_iam_role" "schedule" {
  count = local.scheduled ? 1 : 0

  name        = "${var.name}-schedule"
  description = "EventBridge Scheduler: start and stop ${var.name} on its schedule"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "scheduler.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = { StringEquals = { "aws:SourceAccount" = local.account_id } }
    }]
  })
}

resource "aws_iam_role_policy" "schedule" {
  count = local.scheduled ? 1 : 0

  name = "start-stop"
  role = aws_iam_role.schedule[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ec2:StartInstances", "ec2:StopInstances"]
      Resource = aws_instance.this.arn
    }]
  })
}

resource "aws_scheduler_schedule" "start" {
  count = local.scheduled ? 1 : 0

  name                         = "${var.name}-start"
  description                  = "Start ${var.name} at ${var.schedule.on} (${var.schedule.timezone})"
  schedule_expression          = local.schedule_cron.start
  schedule_expression_timezone = var.schedule.timezone

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = "arn:aws:scheduler:::aws-sdk:ec2:startInstances"
    role_arn = aws_iam_role.schedule[0].arn
    input    = jsonencode({ InstanceIds = [aws_instance.this.id] })
  }
}

resource "aws_scheduler_schedule" "stop" {
  count = local.scheduled ? 1 : 0

  name                         = "${var.name}-stop"
  description                  = "Stop ${var.name} at ${var.schedule.off} (${var.schedule.timezone})"
  schedule_expression          = local.schedule_cron.stop
  schedule_expression_timezone = var.schedule.timezone

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = "arn:aws:scheduler:::aws-sdk:ec2:stopInstances"
    role_arn = aws_iam_role.schedule[0].arn
    input    = jsonencode({ InstanceIds = [aws_instance.this.id] })
  }
}
