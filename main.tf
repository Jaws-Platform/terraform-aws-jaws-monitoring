# Root module: the billing normalizer and the monitoring node, wired together
# in one account (the `monitoring/` stack's whole job).
#
#   normalizer  modules/billing-normalizer, <name>-normalizer: the hourly
#               Lambda that rebuilds each changed billing period from the
#               bucket's raw/ layer into normalized/
#   node        modules/monitoring-node, <name>: the instance running Grafana,
#               Prometheus and the exporters, reading normalized/ into its
#               cost database
#
# It only wires the two submodules together. Each can be used on its own, and
# both keep their own defaults and input validation: an input left null here
# takes the submodule's default. The billing bucket (modules/billing-bucket)
# and the AWS export (modules/aws-billing-export) are applied elsewhere, the
# bucket first.

locals {
  # What the node reads is what the normalizer writes.
  node_cost = {
    bucket                   = var.bucket_name
    normalized_prefix        = split("/schema=", module.normalizer.outputs.focus)[0]
    providers                = concat(var.aws == null ? [] : ["aws"], var.databricks == null ? [] : ["databricks"])
    run_join_tags            = var.runs == null ? ["RunId", "TaskId"] : var.runs.join_tags
    budgets                  = var.budgets
    anomaly_floor_usd        = var.anomaly_floor_usd
    databricks_workspace_tag = var.databricks_workspace_tag
  }
}

module "normalizer" {
  source = "./modules/billing-normalizer"

  name                = "${var.name}-normalizer"
  bucket_name         = var.bucket_name
  normalized_prefix   = var.normalized_prefix
  promoted_tags       = var.promoted_tags
  aws                 = var.aws
  databricks          = var.databricks
  runs                = var.runs
  schedule_expression = var.normalizer_schedule_expression
  pandas_layer_arn    = var.pandas_layer_arn
  memory_size         = var.normalizer_memory_size
  log_retention_days  = var.normalizer_log_retention_days
}

module "node" {
  source = "./modules/monitoring-node"

  name      = var.name
  vpc_id    = var.vpc_id
  subnet_id = var.subnet_id
  # tflint-ignore: aws_instance_invalid_type # the ruleset (0.49.0) predates T9g (GA 2026-11-20), the node's default
  instance_type        = var.instance_type
  ami_name             = var.ami_name
  root_volume_gb       = var.root_volume_gb
  data_volume_gb       = var.data_volume_gb
  domain               = var.domain
  zone_id              = var.zone_id
  acme_email           = var.acme_email
  grafana_admin        = var.grafana_admin
  prometheus_retention = var.prometheus_retention
  snapshots            = var.snapshots
  schedule             = var.schedule
  images               = var.images
  extra_dashboards     = var.extra_dashboards
  extra_alert_rules    = var.extra_alert_rules
  thresholds           = var.thresholds
  slack                = var.slack
  cost                 = local.node_cost
}
