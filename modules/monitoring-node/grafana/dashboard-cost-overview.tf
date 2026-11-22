# Cost · Overview (with cost): where the money goes, against the budgets, over
# the last 90 days, in the house style. Every query reads the cost model in the
# cost database (cost-sync's views); days are UTC, amounts billed USD. The
# filters narrow the tiles, the trend and the breakdowns; the budget, mover and
# untagged tables are the model's own scopes. Panels 32, 42 and 53 are the cost
# rules' panels.

locals {
  overview_vars = [
    { name = "provider", label = "Provider", query = "SELECT DISTINCT provider FROM cost.daily ORDER BY 1", column = "provider" },
    { name = "account", label = "Account", query = "SELECT DISTINCT coalesce(account_name, account_id, '') FROM cost.daily ORDER BY 1", column = "coalesce(account_name, account_id, '')" },
    { name = "project", label = "Project", query = "SELECT DISTINCT project FROM cost.daily ORDER BY 1", column = "project" },
    { name = "environment", label = "Environment", query = "SELECT DISTINCT coalesce(environment, '(none)') FROM cost.daily ORDER BY 1", column = "coalesce(environment, '(none)')" },
  ]

  ratio_steps = [
    { color = "green", value = null },
    { color = "yellow", value = local.t.anomaly_ratio.warning },
    { color = "red", value = local.t.anomaly_ratio.critical },
  ]

  # ---------------------------------------------------------------- tiles
  overview_stats = [
    { id = 1, title = "Month to date", description = "Spend so far this month (UTC), for the filters chosen. Partial days count as charged so far.", grid = { x = 0, y = 0, w = 4, h = 4 }, sql = "SELECT sum(billed_cost) AS month_to_date FROM cost.daily WHERE day >= ${local.month_start} AND ${local.cost_filter.overview}", unit = "currencyUSD", steps = local.usd_steps, type = "stat" },
    { id = 2, title = "Forecast vs budget", description = "The month-end forecast as a share of the total budget: the month's complete days, plus the last 7 complete days' average for each day still to come. Yellow at 80 %, red at 100 %, where the forecast alert fires. Filters don't apply.", grid = { x = 4, y = 0, w = 4, h = 4 }, sql = "SELECT forecast_percent FROM cost.month_to_date WHERE scope = 'total'", unit = "percent", steps = local.percent_steps, type = "stat" },
    { id = 3, title = "Budget used", description = "This month's spend as a share of the total budget. Yellow at 80 %, red at 100 %, where the month-to-date alert fires. Filters don't apply.", grid = { x = 8, y = 0, w = 4, h = 4 }, sql = "SELECT used_percent FROM cost.month_to_date WHERE scope = 'total'", unit = "percent", steps = local.percent_steps, type = "gauge" },
    { id = 4, title = "Yesterday (partial)", description = "Yesterday's spend (UTC) so far: billing data keeps arriving for about two days.", grid = { x = 12, y = 0, w = 3, h = 4 }, sql = "SELECT sum(billed_cost) AS yesterday FROM cost.daily WHERE day = (cost.now() AT TIME ZONE 'UTC')::date - 1 AND ${local.cost_filter.overview}", unit = "currencyUSD", steps = local.usd_steps, type = "stat" },
    { id = 5, title = "vs last month, same day", description = "This month to date against last month up to the same day of the month, as a change in %.", grid = { x = 15, y = 0, w = 3, h = 4 }, sql = "SELECT 100 * (sum(billed_cost) FILTER (WHERE day >= ${local.month_start}) - sum(billed_cost) FILTER (WHERE day < ${local.month_start})) / nullif(sum(billed_cost) FILTER (WHERE day < ${local.month_start}), 0) AS change FROM cost.daily WHERE day >= (${local.month_start} - interval '1 month')::date AND (day >= ${local.month_start} OR day < (${local.month_start} - interval '1 month')::date + extract(day FROM cost.now() AT TIME ZONE 'UTC')::int) AND ${local.cost_filter.overview}", unit = "percent", steps = local.usd_steps, type = "stat" },
    { id = 6, title = "Untagged this month", description = "This month's spend with no Project tag, tax and credits aside (they can't carry one).", grid = { x = 18, y = 0, w = 3, h = 4 }, sql = "SELECT sum(billed_cost) AS untagged FROM cost.untagged WHERE day >= ${local.month_start}", unit = "currencyUSD", steps = local.usd_steps, type = "stat" },
    { id = 7, title = "Data as of", description = "The newest complete day: 48 hours past its end, so its charges are in. Newer days are partial.", grid = { x = 21, y = 0, w = 3, h = 4 }, sql = "SELECT to_char(day, 'YYYY-MM-DD') AS data_as_of FROM cost.as_of", unit = "none", steps = local.usd_steps, type = "stat" },
  ]

  # ----------------------------------------------------- series and bars
  overview_series = [
    { id = 12, title = "Daily spend by provider", description = "Each UTC day's spend, stacked by provider. The last two days are partial.", grid = { x = 0, y = 7, w = 16, h = 8 }, sql = "SELECT day::timestamp AS time, provider AS metric, sum(billed_cost) AS value FROM cost.daily WHERE $__timeFilter(day) AND ${local.cost_filter.overview} GROUP BY 1, 2 ORDER BY 1", time_from = null },
    { id = 13, title = "Monthly totals", description = "Each month's spend over the last 12 months.", grid = { x = 16, y = 7, w = 8, h = 8 }, sql = "SELECT date_trunc('month', day)::timestamp AS time, 'spend' AS metric, sum(billed_cost) AS value FROM cost.daily WHERE $__timeFilter(day) AND ${local.cost_filter.overview} GROUP BY 1 ORDER BY 1", time_from = "1y" },
  ]

  overview_bars = [
    { id = 22, title = "Month to date by project", description = "This month's spend by project; (untagged) has no Project tag.", grid = { x = 0, y = 18, w = 6, h = 8 }, sql = "SELECT project AS metric, sum(billed_cost) AS value FROM cost.daily WHERE day >= ${local.month_start} AND ${local.cost_filter.overview} GROUP BY 1 ORDER BY 2 DESC" },
    { id = 23, title = "Month to date by service (top 10)", description = "This month's ten costliest services.", grid = { x = 6, y = 18, w = 6, h = 8 }, sql = "SELECT service AS metric, sum(billed_cost) AS value FROM cost.daily WHERE day >= ${local.month_start} AND ${local.cost_filter.overview} GROUP BY 1 ORDER BY 2 DESC LIMIT 10" },
    { id = 24, title = "Month to date by account", description = "This month's spend by account (Databricks: by workspace).", grid = { x = 12, y = 18, w = 6, h = 8 }, sql = "SELECT coalesce(account_name, account_id, '') AS metric, sum(billed_cost) AS value FROM cost.daily WHERE day >= ${local.month_start} AND ${local.cost_filter.overview} GROUP BY 1 ORDER BY 2 DESC" },
    { id = 25, title = "Month to date by provider", description = "This month's spend by provider.", grid = { x = 18, y = 18, w = 6, h = 8 }, sql = "SELECT provider AS metric, sum(billed_cost) AS value FROM cost.daily WHERE day >= ${local.month_start} AND ${local.cost_filter.overview} GROUP BY 1 ORDER BY 2 DESC" },
  ]

  # -------------------------------------------------------------- tables
  overview_tables = [
    { id = 32, title = "Budgets", description = "Each budget: what it allows, this month's spend, the month-end forecast, and both as a share. Yellow at 80 %, red at 100 %: the forecast alert warns over 100 %, the month-to-date alert is critical over 100 %.", grid = { x = 0, y = 29, w = 24, h = 8 }, sql = "SELECT scope, name, budget, mtd, forecast, used_percent, forecast_percent FROM cost.month_to_date WHERE budget IS NOT NULL ORDER BY scope, name", colour = { used_percent = local.percent_steps, forecast_percent = local.percent_steps }, units = { budget = "currencyUSD", mtd = "currencyUSD", forecast = "currencyUSD", used_percent = "percent", forecast_percent = "percent" } },
    { id = 42, title = "Furthest above their 14-day norm", description = "Each of the last three days' spend against the median of the 14 complete days before it, for the total, each project and each service (a provider that reports late is judged when its day lands). The anomaly alert warns at ${local.t.anomaly_ratio.warning}x and is critical at ${local.t.anomaly_ratio.critical}x (total and projects, when the excess is over the floor).", grid = { x = 0, y = 40, w = 24, h = 8 }, sql = "SELECT kind, name, day, spend, median14, ratio, excess FROM cost.anomalies WHERE ratio IS NOT NULL ORDER BY ratio DESC LIMIT 10", colour = { ratio = local.ratio_steps }, units = { spend = "currencyUSD", median14 = "currencyUSD", excess = "currencyUSD", ratio = "none" } },
    { id = 52, title = "Untagged this month", description = "This month's untagged spend by account and service. Tax and credits aren't counted; a public IPv4 address is a charge AWS never tags.", grid = { x = 0, y = 51, w = 12, h = 8 }, sql = "SELECT account_name, service, sum(billed_cost) AS spend FROM cost.untagged WHERE day >= ${local.month_start} GROUP BY 1, 2 ORDER BY 3 DESC", colour = {}, units = { spend = "currencyUSD" } },
    { id = 53, title = "New untagged spend", description = "Untagged spend by account and service that started on the newest day or the day before, after none in the 14 days before, and what it has spent since. It alerts over USD ${local.t.untagged_daily_usd.warning}, so a steady charge alerts only once.", grid = { x = 12, y = 51, w = 12, h = 8 }, sql = "SELECT account_name, service, first_day, spend FROM cost.untagged_new WHERE is_new ORDER BY spend DESC", colour = { spend = [{ color = "green", value = null }, { color = "yellow", value = local.t.untagged_daily_usd.warning }] }, units = { spend = "currencyUSD" } },
  ]

  overview_rows = [
    { id = 10, y = 4, title = "Trend", text = "**Trend.** Daily spend over the last 90 days, and each month's total over the last year. Days are UTC; the newest two are still filling in." },
    { id = 20, y = 15, title = "Where it goes", text = "**Where it goes.** This month's spend by project, service, account and provider." },
    { id = 30, y = 26, title = "Budgets", text = "**Budgets.** Each monthly budget against its spend and forecast. The forecast alert warns when the month-end forecast is over a budget; the month-to-date alert is critical when the spend already is." },
    { id = 40, y = 37, title = "Movers", text = "**Movers.** What is furthest above its usual daily spend: the newest day against the median of the 14 complete days before it." },
    { id = 50, y = 48, title = "Untagged", text = "**Untagged.** Spend no Project tag claims. Tax and credits can't carry tags; new untagged spend alerts once, on its first day." },
  ]

  overview_board = {
    uid    = "cost-overview"
    title  = "Cost · Overview"
    time   = { from = "now-90d", to = "now" }
    stats  = local.overview_stats
    series = local.overview_series
    bars   = local.overview_bars
    tables = local.overview_tables
    rows   = local.overview_rows
  }
}
