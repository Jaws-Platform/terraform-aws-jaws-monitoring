output "arn" {
  description = "The export's ARN."
  value       = aws_bcmdataexports_export.this.arn
}

output "name" {
  description = "The export's name."
  value       = var.name
}

output "delivery_prefix" {
  description = "Where AWS delivers: `<delivery_prefix>/data/billing_period=YYYY-MM/<timestamp>-<execution-id>/` and `<delivery_prefix>/metadata/billing_period=YYYY-MM/<name>-Manifest.json`."
  value       = "${var.prefix}/${var.name}"
}
