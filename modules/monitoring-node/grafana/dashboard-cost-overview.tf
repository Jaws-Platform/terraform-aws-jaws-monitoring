# Cost · Overview (with cost): where the money goes, against the budgets, over
# the last 90 days, in the house style. Every query reads the cost model in the
# cost database (cost-sync's views); days are UTC, amounts billed USD. The
# filters narrow the tiles, the trend and the breakdowns; the budget, mover and
# untagged tables are the model's own scopes. Panels 32, 42 and 53 are the cost
# rules' panels.

locals {
  cost_ds = { type = "grafana-postgresql-datasource", uid = "cost" }

  # The filters, as Grafana expands its multi-value variables into SQL lists.
  cost_filter = "provider IN ($provider) AND coalesce(account_name, account_id, '') IN ($account) AND project IN ($project) AND coalesce(environment, '(none)') IN ($environment)"
  month_start = "date_trunc('month', cost.now() AT TIME ZONE 'UTC')::date"

  cost_variables = [
    for v in [
      { name = "provider", label = "Provider", query = "SELECT DISTINCT provider FROM cost.daily ORDER BY 1" },
      { name = "account", label = "Account", query = "SELECT DISTINCT coalesce(account_name, account_id, '') FROM cost.daily ORDER BY 1" },
      { name = "project", label = "Project", query = "SELECT DISTINCT project FROM cost.daily ORDER BY 1" },
      { name = "environment", label = "Environment", query = "SELECT DISTINCT coalesce(environment, '(none)') FROM cost.daily ORDER BY 1" },
      ] : {
      name       = v.name
      label      = v.label
      type       = "query"
      datasource = local.cost_ds
      query      = v.query
      definition = v.query
      refresh    = 2
      multi      = true
      includeAll = true
      current    = { text = "All", value = "$__all" }
      sort       = 1
    }
  ]

  usd_steps     = [{ color = "blue", value = null }]
  percent_steps = [{ color = "green", value = null }, { color = "yellow", value = 80 }, { color = "red", value = 100 }]
  ratio_steps = [
    { color = "green", value = null },
    { color = "yellow", value = local.t.anomaly_ratio.warning },
    { color = "red", value = local.t.anomaly_ratio.critical },
  ]

  # ---------------------------------------------------------------- tiles
  overview_stats = [
    { id = 1, title = "Month to date", description = "Spend so far this month (UTC), for the filters chosen. Partial days count as charged so far.", grid = { x = 0, y = 0, w = 4, h = 4 }, sql = "SELECT sum(billed_cost) AS month_to_date FROM cost.daily WHERE day >= ${local.month_start} AND ${local.cost_filter}", unit = "currencyUSD", steps = local.usd_steps, type = "stat" },
    { id = 2, title = "Forecast vs budget", description = "The month-end forecast as a share of the total budget: the month's complete days, plus the last 7 complete days' average for each day still to come. Yellow at 80 %, red at 100 %, where the forecast alert fires. Filters don't apply.", grid = { x = 4, y = 0, w = 4, h = 4 }, sql = "SELECT forecast_percent FROM cost.month_to_date WHERE scope = 'total'", unit = "percent", steps = local.percent_steps, type = "stat" },
    { id = 3, title = "Budget used", description = "This month's spend as a share of the total budget. Yellow at 80 %, red at 100 %, where the month-to-date alert fires. Filters don't apply.", grid = { x = 8, y = 0, w = 4, h = 4 }, sql = "SELECT used_percent FROM cost.month_to_date WHERE scope = 'total'", unit = "percent", steps = local.percent_steps, type = "gauge" },
    { id = 4, title = "Yesterday (partial)", description = "Yesterday's spend (UTC) so far: billing data keeps arriving for about two days.", grid = { x = 12, y = 0, w = 3, h = 4 }, sql = "SELECT sum(billed_cost) AS yesterday FROM cost.daily WHERE day = (cost.now() AT TIME ZONE 'UTC')::date - 1 AND ${local.cost_filter}", unit = "currencyUSD", steps = local.usd_steps, type = "stat" },
    { id = 5, title = "vs last month, same day", description = "This month to date against last month up to the same day of the month, as a change in %.", grid = { x = 15, y = 0, w = 3, h = 4 }, sql = "SELECT 100 * (sum(billed_cost) FILTER (WHERE day >= ${local.month_start}) - sum(billed_cost) FILTER (WHERE day < ${local.month_start})) / nullif(sum(billed_cost) FILTER (WHERE day < ${local.month_start}), 0) AS change FROM cost.daily WHERE day >= (${local.month_start} - interval '1 month')::date AND (day >= ${local.month_start} OR day < (${local.month_start} - interval '1 month')::date + extract(day FROM cost.now() AT TIME ZONE 'UTC')::int) AND ${local.cost_filter}", unit = "percent", steps = local.usd_steps, type = "stat" },
    { id = 6, title = "Untagged this month", description = "This month's spend with no Project tag, tax and credits aside (they can't carry one).", grid = { x = 18, y = 0, w = 3, h = 4 }, sql = "SELECT sum(billed_cost) AS untagged FROM cost.untagged WHERE day >= ${local.month_start}", unit = "currencyUSD", steps = local.usd_steps, type = "stat" },
    { id = 7, title = "Data as of", description = "The newest complete day: 48 hours past its end, so its charges are in. Newer days are partial.", grid = { x = 21, y = 0, w = 3, h = 4 }, sql = "SELECT to_char(day, 'YYYY-MM-DD') AS data_as_of FROM cost.as_of", unit = "none", steps = local.usd_steps, type = "stat" },
  ]

  # ----------------------------------------------------- series and bars
  overview_series = [
    { id = 12, title = "Daily spend by provider", description = "Each UTC day's spend, stacked by provider. The last two days are partial.", grid = { x = 0, y = 7, w = 16, h = 8 }, sql = "SELECT day::timestamp AS time, provider AS metric, sum(billed_cost) AS value FROM cost.daily WHERE $__timeFilter(day::timestamp) AND ${local.cost_filter} GROUP BY 1, 2 ORDER BY 1", time_from = null },
    { id = 13, title = "Monthly totals", description = "Each month's spend over the last 12 months.", grid = { x = 16, y = 7, w = 8, h = 8 }, sql = "SELECT date_trunc('month', day)::timestamp AS time, 'spend' AS metric, sum(billed_cost) AS value FROM cost.daily WHERE $__timeFilter(day::timestamp) AND ${local.cost_filter} GROUP BY 1 ORDER BY 1", time_from = "1y" },
  ]

  overview_bars = [
    { id = 22, title = "Month to date by project", description = "This month's spend by project; (untagged) has no Project tag.", grid = { x = 0, y = 18, w = 6, h = 8 }, sql = "SELECT project AS metric, sum(billed_cost) AS value FROM cost.daily WHERE day >= ${local.month_start} AND ${local.cost_filter} GROUP BY 1 ORDER BY 2 DESC" },
    { id = 23, title = "Month to date by service (top 10)", description = "This month's ten costliest services.", grid = { x = 6, y = 18, w = 6, h = 8 }, sql = "SELECT service AS metric, sum(billed_cost) AS value FROM cost.daily WHERE day >= ${local.month_start} AND ${local.cost_filter} GROUP BY 1 ORDER BY 2 DESC LIMIT 10" },
    { id = 24, title = "Month to date by account", description = "This month's spend by account (Databricks: by workspace).", grid = { x = 12, y = 18, w = 6, h = 8 }, sql = "SELECT coalesce(account_name, account_id, '') AS metric, sum(billed_cost) AS value FROM cost.daily WHERE day >= ${local.month_start} AND ${local.cost_filter} GROUP BY 1 ORDER BY 2 DESC" },
    { id = 25, title = "Month to date by provider", description = "This month's spend by provider.", grid = { x = 18, y = 18, w = 6, h = 8 }, sql = "SELECT provider AS metric, sum(billed_cost) AS value FROM cost.daily WHERE day >= ${local.month_start} AND ${local.cost_filter} GROUP BY 1 ORDER BY 2 DESC" },
  ]

  # -------------------------------------------------------------- tables
  overview_tables = [
    { id = 32, title = "Budgets", description = "Each budget: what it allows, this month's spend, the month-end forecast, and both as a share. Yellow at 80 %, red at 100 %: the forecast alert warns over 100 %, the month-to-date alert is critical over 100 %.", grid = { x = 0, y = 29, w = 24, h = 8 }, sql = "SELECT scope, name, budget, mtd, forecast, used_percent, forecast_percent FROM cost.month_to_date WHERE budget IS NOT NULL ORDER BY scope, name", colour = { used_percent = local.percent_steps, forecast_percent = local.percent_steps }, units = { budget = "currencyUSD", mtd = "currencyUSD", forecast = "currencyUSD", used_percent = "percent", forecast_percent = "percent" } },
    { id = 42, title = "Furthest above their 14-day norm", description = "The newest day's spend against the median of the 14 complete days before it, for the total, each project and each service. The anomaly alert warns at ${local.t.anomaly_ratio.warning}x and is critical at ${local.t.anomaly_ratio.critical}x (total and projects, when the excess is over the floor).", grid = { x = 0, y = 40, w = 24, h = 8 }, sql = "SELECT kind, name, day, spend, median14, ratio, excess FROM cost.anomalies WHERE ratio IS NOT NULL ORDER BY ratio DESC LIMIT 10", colour = { ratio = local.ratio_steps }, units = { spend = "currencyUSD", median14 = "currencyUSD", excess = "currencyUSD", ratio = "none" } },
    { id = 52, title = "Untagged this month", description = "This month's untagged spend by account and service. Tax and credits aren't counted; a public IPv4 address is a charge AWS never tags.", grid = { x = 0, y = 51, w = 12, h = 8 }, sql = "SELECT account_name, service, sum(billed_cost) AS spend FROM cost.untagged WHERE day >= ${local.month_start} GROUP BY 1, 2 ORDER BY 3 DESC", colour = {}, units = { spend = "currencyUSD" } },
    { id = 53, title = "New untagged spend", description = "The newest day's untagged spend by account and service, with what the same pair spent untagged in the 14 days before. It alerts when that was nothing and the day is over USD ${local.t.untagged_daily_usd.warning}, so a steady charge alerts only once.", grid = { x = 12, y = 51, w = 12, h = 8 }, sql = "SELECT account_name, service, spend, prior_spend FROM cost.untagged_new ORDER BY spend DESC", colour = { spend = [{ color = "green", value = null }, { color = "yellow", value = local.t.untagged_daily_usd.warning }] }, units = { spend = "currencyUSD", prior_spend = "currencyUSD" } },
  ]

  overview_rows = [
    { id = 10, y = 4, title = "Trend", text = "**Trend.** Daily spend over the last 90 days, and each month's total over the last year. Days are UTC; the newest two are still filling in." },
    { id = 20, y = 15, title = "Where it goes", text = "**Where it goes.** This month's spend by project, service, account and provider." },
    { id = 30, y = 26, title = "Budgets", text = "**Budgets.** Each monthly budget against its spend and forecast. The forecast alert warns when the month-end forecast is over a budget; the month-to-date alert is critical when the spend already is." },
    { id = 40, y = 37, title = "Movers", text = "**Movers.** What is furthest above its usual daily spend: the newest day against the median of the 14 complete days before it." },
    { id = 50, y = 48, title = "Untagged", text = "**Untagged.** Spend no Project tag claims. Tax and credits can't carry tags; new untagged spend alerts once, on its first day." },
  ]

  cost_target = { datasource = local.cost_ds, editorMode = "code", rawQuery = true, refId = "A" }

  overview_panels = concat(
    [
      for s in local.overview_stats : {
        id      = s.id, type = s.type, title = s.title, description = s.description, datasource = local.cost_ds, gridPos = s.grid
        targets = [merge(local.cost_target, { rawSql = s.sql, format = "table" })]
        options = merge(
          { reduceOptions = { calcs = ["lastNotNull"], fields = "/.*/", values = false } },
          s.type == "stat" ? { colorMode = "value", graphMode = "none", textMode = "value", justifyMode = "auto" } : { showThresholdMarkers = true },
        )
        fieldConfig = { defaults = { unit = s.unit, decimals = 0, noValue = "No data", color = { mode = "thresholds" }, thresholds = { mode = "absolute", steps = s.steps } }, overrides = [] }
      }
    ],
    [
      for s in local.overview_series : merge(
        {
          id      = s.id, type = "timeseries", title = s.title, description = s.description, datasource = local.cost_ds, gridPos = s.grid
          targets = [merge(local.cost_target, { rawSql = s.sql, format = "time_series" })]
          options = { legend = { displayMode = "list", placement = "bottom", showLegend = true }, tooltip = { mode = "multi", sort = "desc" } }
          fieldConfig = {
            defaults  = { unit = "currencyUSD", custom = { drawStyle = "bars", fillOpacity = 80, lineWidth = 1, stacking = { mode = "normal", group = "A" } } }
            overrides = []
          }
        },
        { for k, v in { timeFrom = s.time_from } : k => v if v != null },
      )
    ],
    [
      for s in local.overview_bars : {
        id          = s.id, type = "bargauge", title = s.title, description = s.description, datasource = local.cost_ds, gridPos = s.grid
        targets     = [merge(local.cost_target, { rawSql = s.sql, format = "table" })]
        options     = { reduceOptions = { calcs = ["lastNotNull"], fields = "", values = true }, orientation = "horizontal", displayMode = "basic", showUnfilled = true }
        fieldConfig = { defaults = { unit = "currencyUSD", decimals = 0, color = { mode = "fixed", fixedColor = "blue" } }, overrides = [] }
      }
    ],
    [
      for s in local.overview_tables : {
        id      = s.id, type = "table", title = s.title, description = s.description, datasource = local.cost_ds, gridPos = s.grid
        targets = [merge(local.cost_target, { rawSql = s.sql, format = "table" })]
        options = { showHeader = true, cellHeight = "sm" }
        fieldConfig = {
          defaults = { custom = { align = "auto" } }
          overrides = concat(
            [for field, unit in s.units : { matcher = { id = "byName", options = field }, properties = [{ id = "unit", value = unit }, { id = "decimals", value = 2 }] }],
            [for field, steps in s.colour : { matcher = { id = "byName", options = field }, properties = [
              { id = "thresholds", value = { mode = "absolute", steps = steps } },
              { id = "custom.cellOptions", value = { type = "color-background" } },
            ] }],
          )
        }
      }
    ],
    [for r in local.overview_rows : { id = r.id, type = "row", title = r.title, collapsed = false, gridPos = { x = 0, y = r.y, w = 24, h = 1 }, panels = [] }],
    [for r in local.overview_rows : { id = r.id + 1, type = "text", title = "", transparent = true, gridPos = { x = 0, y = r.y + 1, w = 24, h = 2 }, options = { mode = "markdown", content = r.text } }],
  )

  overview_panels_by_id = { for p in local.overview_panels : format("%03d", p.id) => p }

  cost_overview = {
    uid           = "cost-overview"
    title         = "Cost · Overview"
    tags          = ["cost"]
    timezone      = "browser"
    editable      = false
    graphTooltip  = 1
    schemaVersion = 39
    refresh       = "30s"
    time          = { from = "now-90d", to = "now" }
    templating    = { list = local.cost_variables }
    panels        = [for k in sort(keys(local.overview_panels_by_id)) : local.overview_panels_by_id[k]]
  }
}
