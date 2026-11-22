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
  cost              = var.cost == null ? null : { providers = var.cost.providers }
  extra_dashboards  = var.extra_dashboards
  extra_alert_rules = var.extra_alert_rules
}

locals {
  cost_on = var.cost != null

  # cost-sync's files, in the bundle: its config and the script itself, so a
  # change to either never replaces the instance (user data only has its units).
  cost_sync_files = local.cost_on ? {
    "cost-sync/config.json" = jsonencode({
      bucket        = var.cost.bucket
      prefix        = var.cost.normalized_prefix
      providers     = sort(tolist(var.cost.providers))
      run_join_tags = var.cost.run_join_tags
    })
    "cost-sync/monitoring-cost-sync.py" = file("${path.module}/files/monitoring-cost-sync.py")
  } : {}

  # Each Slack channel's webhook: the reconciler reads its parameter into the
  # variable Grafana's contact point expands (variable name => parameter).
  slack_channels = var.slack == null ? {} : var.slack.channels
  slack_secrets  = { for channel, env in module.grafana.webhook_env : env => local.slack_channels[channel] }
}
