# Host monitoring: the Grafana config module renders every file under grafana/
# in the bundle (data sources, dashboards, alert rules, Slack routing).

module "grafana" {
  source = "./grafana"

  region            = local.region
  instance_id       = aws_instance.this.id
  instance_type     = var.instance_type
  domain            = var.domain
  thresholds        = var.thresholds
  slack             = var.slack
  extra_dashboards  = var.extra_dashboards
  extra_alert_rules = var.extra_alert_rules
}

locals {
  # Each Slack channel's webhook: the reconciler reads its parameter into the
  # variable Grafana's contact point expands (variable name => parameter).
  slack_channels = var.slack == null ? {} : var.slack.channels
  slack_secrets  = { for channel, env in module.grafana.webhook_env : env => local.slack_channels[channel] }
}
