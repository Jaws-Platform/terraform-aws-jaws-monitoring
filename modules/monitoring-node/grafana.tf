# Host monitoring: the Grafana config module renders every file under grafana/
# in the bundle (data sources, dashboards, alert rules, Slack routing).

module "grafana" {
  source = "./grafana"

  region            = local.region
  instance_id       = aws_instance.this.id
  instance_type     = var.instance_type
  domain            = var.domain
  thresholds        = var.thresholds
  extra_dashboards  = var.extra_dashboards
  extra_alert_rules = var.extra_alert_rules
}

locals {
  # Secrets the reconciler reads for Grafana beyond its admin sign-in
  # (variable name => SSM parameter), and the parameters the role may read.
  extra_bundle_secrets    = {}
  extra_secret_parameters = []
}
