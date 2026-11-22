# The cost rules (area = cost): SQL on the cost database, in table form, so
# each row is one alert instance labelled by its string columns. They read the
# cost model (cost-sync's views) and link the Cost · Overview panels. With no
# cost, none is rendered and all are deleted.

locals {
  anomaly_floor = local.cost_on ? var.cost.anomaly_floor_usd : 0

  cost_rule_specs = [
    { key = "budget-forecast", title = "Budget: month-end forecast", source = "postgres", query = "SELECT scope, name, forecast_percent FROM cost.month_to_date WHERE budget IS NOT NULL", op = "gt", warning = 100, critical = null, offset = 0, for = "2m", panel = 32, needed = local.cost_on, summary = "The month-end forecast is over a budget (over %v %% of it): the month's complete days, plus the last 7 complete days' average for every day to come." },
    { key = "budget-spent", title = "Budget: month to date", source = "postgres", query = "SELECT scope, name, used_percent FROM cost.month_to_date WHERE budget IS NOT NULL", op = "gt", warning = null, critical = 100, offset = 0, for = "2m", panel = 32, needed = local.cost_on, summary = "This month's spend is already over a budget (over %v %% of it)." },
    { key = "anomaly", title = "Daily spend anomaly", source = "postgres", query = "SELECT kind, name, ratio FROM cost.anomalies WHERE kind IN ('total', 'project') AND excess > ${local.anomaly_floor} AND ratio IS NOT NULL", op = "gt", warning = local.t.anomaly_ratio.warning, critical = local.t.anomaly_ratio.critical, offset = 0, for = "2m", panel = 42, needed = local.cost_on, summary = "The newest day's spend is over %vx the median of the 14 complete days before it, and more than USD ${local.anomaly_floor} above it. Planning an expensive run? Silence this rule first." },
    { key = "untagged-new", title = "New untagged spend", source = "postgres", query = "SELECT account_name, service, spend FROM cost.untagged_new WHERE prior_spend = 0", op = "gt", warning = local.t.untagged_daily_usd.warning, critical = null, offset = 0, for = "2m", panel = 53, needed = local.cost_on, summary = "An account and service with no untagged spend in the 14 days before spent over USD %v untagged on the newest day." },
  ]
}
