output "files" {
  description = "Every file under grafana/ in the config bundle, keyed by its path in the bundle."
  value       = local.files

  precondition {
    condition     = length(local.problems) == 0
    error_message = "Grafana provisioning problems: ${join("; ", local.problems)}"
  }
}

output "webhook_env" {
  description = "Each Slack channel's webhook environment variable, which Grafana expands in its contact point."
  value       = local.webhook_env
}
