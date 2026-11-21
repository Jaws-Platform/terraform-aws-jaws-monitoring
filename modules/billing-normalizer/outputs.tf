output "function_name" {
  description = "The normalizer function's name, to invoke it by hand."
  value       = aws_lambda_function.this.function_name
}

output "function_arn" {
  description = "The normalizer function's ARN, known at plan."
  value       = local.function_arn
}

output "role_name" {
  description = "The function's role."
  value       = aws_iam_role.this.name
}

output "role_arn" {
  description = "The function's role ARN."
  value       = aws_iam_role.this.arn
}

output "log_group_name" {
  description = "The function's CloudWatch log group."
  value       = aws_cloudwatch_log_group.this.name
}

output "schedule_name" {
  description = "The EventBridge Scheduler schedule that runs it."
  value       = aws_scheduler_schedule.this.name
}

output "outputs" {
  description = "Where it writes: the FOCUS table, the runs event table and the run records, under the bucket."
  value = {
    focus       = "${var.normalized_prefix}/schema=focus-1.2"
    runs        = "${var.normalized_prefix}/schema=runs-1"
    run_records = "${var.normalized_prefix}/_runs"
  }
}
