# Cost · Project (with cost): one project's spend by component, service and
# environment, daily and month to date, against its budget (6.7). The project
# is one value; the budget tiles read the model's project scope and ignore the
# environment filter.

locals {
  project_vars = [
    { name = "project", label = "Project", query = "SELECT DISTINCT project FROM cost.daily WHERE project <> '(untagged)' ORDER BY 1", column = "project", multi = false },
    { name = "environment", label = "Environment", query = "SELECT DISTINCT coalesce(environment, '(none)') FROM cost.daily ORDER BY 1", column = "coalesce(environment, '(none)')" },
  ]

  project_scope = "FROM cost.month_to_date WHERE scope = 'project' AND name = $${project:sqlstring}"
  project_rows  = "FROM cost.daily WHERE $__timeFilter(day) AND ${local.cost_filter.project}"
  project_month = "FROM cost.daily WHERE day >= ${local.month_start} AND ${local.cost_filter.project}"

  project_board = {
    uid   = "cost-project"
    title = "Cost · Project"
    time  = { from = "now-90d", to = "now" }

    stats = [
      { id = 1, type = "stat", title = "Month to date", description = "The project's spend so far this month (UTC), for the environments chosen. Partial days count as charged so far.", grid = { x = 0, y = 0, w = 4, h = 4 }, sql = "SELECT sum(billed_cost) AS month_to_date ${local.project_month}", unit = "currencyUSD", steps = local.usd_steps },
      { id = 2, type = "stat", title = "Budget", description = "The project's monthly budget (cost.budgets.projects). No budget: none is set.", grid = { x = 4, y = 0, w = 4, h = 4 }, sql = "SELECT budget ${local.project_scope}", unit = "currencyUSD", steps = local.usd_steps, no_value = "No budget" },
      { id = 3, type = "stat", title = "Forecast", description = "The month-end forecast: the month's complete days, plus, for each day not complete yet, what it has so far or the last 7 complete days' average, whichever is more. All environments.", grid = { x = 8, y = 0, w = 4, h = 4 }, sql = "SELECT forecast ${local.project_scope}", unit = "currencyUSD", steps = local.usd_steps },
      { id = 4, type = "gauge", title = "Budget used", description = "This month's spend as a share of the budget. Yellow at 80 %, red at 100 %, where the month-to-date alert fires. All environments.", grid = { x = 12, y = 0, w = 4, h = 4 }, sql = "SELECT used_percent ${local.project_scope}", unit = "percent", steps = local.percent_steps, no_value = "No budget" },
      { id = 5, type = "stat", title = "Forecast vs budget", description = "The month-end forecast as a share of the budget. Yellow at 80 %, red at 100 %, where the forecast alert warns. All environments.", grid = { x = 16, y = 0, w = 4, h = 4 }, sql = "SELECT forecast_percent ${local.project_scope}", unit = "percent", steps = local.percent_steps, no_value = "No budget" },
      { id = 6, type = "stat", title = "Yesterday (partial)", description = "Yesterday's spend (UTC) so far: billing data keeps arriving for about two days.", grid = { x = 20, y = 0, w = 4, h = 4 }, sql = "SELECT sum(billed_cost) AS yesterday FROM cost.daily WHERE day = (cost.now() AT TIME ZONE 'UTC')::date - 1 AND ${local.cost_filter.project}", unit = "currencyUSD", steps = local.usd_steps },
    ]

    series = [
      {
        id          = 12, title = "Running spend each month, against the budget", grid = { x = 0, y = 7, w = 24, h = 8 }, draw = "line", stack = false
        description = "Each month's spend so far, day by day (it starts again on the 1st), with the monthly budget as a dashed red line. Crossing it is where the month-to-date alert fires."
        sql         = "SELECT day::timestamp AS time, 'spent' AS metric, sum(sum(billed_cost)) OVER (PARTITION BY date_trunc('month', day) ORDER BY day) AS value FROM cost.daily WHERE day >= date_trunc('month', $__timeFrom()::date)::date AND day <= $__timeTo()::date AND ${local.cost_filter.project} GROUP BY day UNION ALL SELECT g::timestamp, 'budget', b.monthly_usd FROM cost.budgets b, generate_series($__timeFrom()::date, $__timeTo()::date, interval '1 day') AS g WHERE b.scope = 'project' AND b.name = $${project:sqlstring} ORDER BY 1"
        overrides = [{ matcher = { id = "byName", options = "budget" }, properties = [
          { id = "custom.lineStyle", value = { fill = "dash", dash = [10, 10] } },
          { id = "color", value = { mode = "fixed", fixedColor = "red" } },
        ] }]
      },
      { id = 22, title = "Daily spend by component", description = "Each UTC day's spend, stacked by the Component tag ((none) without one). The last two days are partial.", grid = { x = 0, y = 18, w = 8, h = 8 }, sql = "SELECT day::timestamp AS time, coalesce(component, '(none)') AS metric, sum(billed_cost) AS value ${local.project_rows} GROUP BY 1, 2 ORDER BY 1" },
      { id = 23, title = "Daily spend by service", description = "Each UTC day's spend, stacked by service: the 8 costliest over the range, the rest as other.", grid = { x = 8, y = 18, w = 8, h = 8 }, sql = "WITH top AS (SELECT service ${local.project_rows} GROUP BY service ORDER BY sum(billed_cost) DESC LIMIT 8) SELECT day::timestamp AS time, CASE WHEN service IN (SELECT service FROM top) THEN service ELSE 'other' END AS metric, sum(billed_cost) AS value ${local.project_rows} GROUP BY 1, 2 ORDER BY 1" },
      { id = 24, title = "Daily spend by environment", description = "Each UTC day's spend, stacked by the Environment tag ((none) without one).", grid = { x = 16, y = 18, w = 8, h = 8 }, sql = "SELECT day::timestamp AS time, coalesce(environment, '(none)') AS metric, sum(billed_cost) AS value ${local.project_rows} GROUP BY 1, 2 ORDER BY 1" },
    ]

    bars = [
      { id = 32, title = "Month to date by component", description = "This month's spend by component.", grid = { x = 0, y = 29, w = 8, h = 8 }, sql = "SELECT coalesce(component, '(none)') AS metric, sum(billed_cost) AS value ${local.project_month} GROUP BY 1 ORDER BY 2 DESC" },
      { id = 33, title = "Month to date by service", description = "This month's spend by service.", grid = { x = 8, y = 29, w = 8, h = 8 }, sql = "SELECT service AS metric, sum(billed_cost) AS value ${local.project_month} GROUP BY 1 ORDER BY 2 DESC" },
      { id = 34, title = "Month to date by environment", description = "This month's spend by environment.", grid = { x = 16, y = 29, w = 8, h = 8 }, sql = "SELECT coalesce(environment, '(none)') AS metric, sum(billed_cost) AS value ${local.project_month} GROUP BY 1 ORDER BY 2 DESC" },
    ]

    rows = [
      { id = 10, y = 4, title = "Against its budget", text = "**Against its budget.** Each month's running spend against the project's monthly budget. Days are UTC; the newest two are still filling in." },
      { id = 20, y = 15, title = "Daily", text = "**Daily.** Where each day's spend went: by component, service and environment." },
      { id = 30, y = 26, title = "Month to date", text = "**Month to date.** This month's spend by component, service and environment." },
    ]
  }
}
