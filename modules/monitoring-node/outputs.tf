output "instance_id" {
  description = "The node's instance."
  value       = aws_instance.this.id
}

output "public_ip" {
  description = "The node's public IPv4 address at creation; it changes on stop and start (the DNS record follows it)."
  value       = aws_instance.this.public_ip
}

output "security_group_id" {
  description = "The node's security group."
  value       = aws_security_group.this.id
}

output "role_name" {
  description = "The node's instance role."
  value       = aws_iam_role.this.name
}

output "role_arn" {
  description = "The node's instance role ARN."
  value       = aws_iam_role.this.arn
}

output "config_bucket" {
  description = "The bucket holding the node's config bundles."
  value       = aws_s3_bucket.config.bucket
}

output "parameter_prefix" {
  description = "The node's SSM parameters: config-bundle (what it should run), status and running-config (what it reports)."
  value       = local.parameter_prefix
}

output "data_volume_id" {
  description = "The data volume, kept when the instance is replaced."
  value       = aws_ebs_volume.data.id
}

output "grafana_url" {
  description = "Where Grafana is: the domain over HTTPS, or a Session Manager port forward to localhost:3000."
  value       = var.domain == null ? "http://localhost:3000 (aws ssm start-session --document-name AWS-StartPortForwardingSession --parameters portNumber=3000,localPortNumber=3000)" : "https://${var.domain}"
}

output "watchdog_function_name" {
  description = "The watchdog Lambda's name, to invoke it by hand (null without Slack)."
  value       = local.watched ? aws_lambda_function.watchdog[0].function_name : null
}

output "off_hours_page_domain_name" {
  description = "The off-hours page's CloudFront domain name (null without the page)."
  value       = local.off_hours_page ? aws_cloudfront_distribution.off_hours_page[0].domain_name : null
}
