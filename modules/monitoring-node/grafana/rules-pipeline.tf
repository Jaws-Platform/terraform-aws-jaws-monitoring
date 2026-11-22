# The pipeline rules (area = pipeline): is the cost data still arriving? They
# read cost-sync's textfile metrics and mirror the host dashboard's Pipeline
# row. With no cost, none is rendered and all are deleted; the AWS and
# Databricks freshness rules need their provider too.

locals {
  pipeline_rule_specs = [
    { key = "cost-sync-late", title = "Cost sync late", source = "prometheus", query = local.q.cost_sync_hours, op = "gt", warning = local.t.cost_sync_hours.warning, critical = local.t.cost_sync_hours.critical, offset = 0, for = "2m", panel = 62, needed = local.cost_on, summary = "cost-sync hasn't succeeded for more than %v hours: the cost dashboards are going stale." },
    { key = "normalizer-late", title = "Normalizer late", source = "prometheus", query = local.q.normalizer_hours, op = "gt", warning = local.t.normalizer_hours.warning, critical = local.t.normalizer_hours.critical, offset = 0, for = "2m", panel = 63, needed = local.cost_on, summary = "No successful normalizer run for more than %v hours." },
    { key = "normalizer-failed", title = "Normalizer run failed", source = "prometheus", query = local.q.normalizer_failed, op = "gt", warning = null, critical = 0.5, offset = 0.5, for = "2m", panel = 68, needed = local.cost_on, summary = "The newest normalizer run failed; its record under _runs/latest.json says why." },
    { key = "aws-charges-stale", title = "AWS charges stale", source = "prometheus", query = local.q.aws_charge_days, op = "gt", warning = local.t.aws_charge_days.warning, critical = local.t.aws_charge_days.critical, offset = 0, for = "2m", panel = 64, needed = contains(local.cost_providers, "aws"), summary = "The newest AWS charge loaded is more than %v days old: the billing export may have stopped." },
    { key = "databricks-stale", title = "Databricks delivery stale", source = "prometheus", query = local.q.databricks_hours, op = "gt", warning = local.t.databricks_delivery_hours.warning, critical = local.t.databricks_delivery_hours.critical, offset = 0, for = "2m", panel = 65, needed = contains(local.cost_providers, "databricks"), summary = "No new Databricks billing for more than %v hours: the billing job may have stopped." },
    { key = "task-run-overdue", title = "Task run possibly leaked", source = "prometheus", query = local.q.task_overdue, op = "gt", warning = null, critical = 0, offset = 0, for = "2m", panel = 66, needed = local.cost_on, summary = "A task run has no finished or swept record an hour past its max hours: its instance may still be running." },
    { key = "task-run-over-ceiling", title = "Task run over its ceiling", source = "prometheus", query = local.q.task_over_ceiling, op = "gt", warning = null, critical = 0, offset = 0, for = "2m", panel = 67, needed = local.cost_on, summary = "A task run's billed cost is over its ceiling." },
  ]
}
