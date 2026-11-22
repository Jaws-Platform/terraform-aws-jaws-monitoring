# Cost · Databricks (with cost, when Databricks is a provider): spend and DBUs
# by product, workspace and SKU at list price, which is what's billed
# (pay-as-you-go by card), and the all-in cost: a workspace's Databricks list
# cost plus the AWS rows its workspace tag names (6.7).

locals {
  databricks_tag = try(var.cost.databricks_workspace_tag, "Workspace")

  databricks_vars = [
    { name = "workspace", label = "Workspace", query = "SELECT DISTINCT workspace FROM cost.databricks_daily ORDER BY 1", column = "workspace" },
    { name = "product", label = "Product", query = "SELECT DISTINCT product FROM cost.databricks_daily ORDER BY 1", column = "product" },
  ]

  # The all-in view has no product: only the workspace filter applies.
  databricks_ws    = "('__all' IN ($workspace) OR workspace IN ($workspace))"
  databricks_month = "FROM cost.databricks_daily WHERE day >= ${local.month_start} AND ${local.cost_filter.databricks}"
  databricks_range = "FROM cost.databricks_daily WHERE $__timeFilter(day) AND ${local.cost_filter.databricks}"
  databricks_aws   = "AWS rows whose ${local.databricks_tag} tag names the workspace: classic clusters' EC2 and EBS, and the workspace's other tagged AWS resources. They count once ${local.databricks_tag} is an active cost allocation tag and workspace names are exported; until then the AWS part is 0."

  databricks_board = {
    uid   = "cost-databricks"
    title = "Cost · Databricks"
    time  = { from = "now-90d", to = "now" }

    stats = [
      { id = 1, type = "stat", title = "Month to date (list price)", description = "Databricks spend so far this month (UTC), at list price: what's billed, paying as you go.", grid = { x = 0, y = 0, w = 5, h = 4 }, sql = "SELECT sum(list_cost) AS month_to_date ${local.databricks_month}", unit = "currencyUSD", steps = local.usd_steps },
      { id = 2, type = "stat", title = "DBUs this month", description = "Databricks Units used so far this month.", grid = { x = 5, y = 0, w = 5, h = 4 }, sql = "SELECT sum(quantity) AS dbus ${local.databricks_month} AND unit = 'DBU'", unit = "none", steps = local.usd_steps },
      { id = 3, type = "stat", title = "Serverless share", description = "The share of this month's list cost on serverless compute.", grid = { x = 10, y = 0, w = 5, h = 4 }, sql = "SELECT 100 * sum(list_cost) FILTER (WHERE serverless) / nullif(sum(list_cost), 0) AS serverless ${local.databricks_month}", unit = "percent", steps = local.usd_steps },
      { id = 4, type = "stat", title = "All-in month to date", description = "This month's Databricks list cost plus the AWS cost tagged to its workspaces. ${local.databricks_aws}", grid = { x = 15, y = 0, w = 5, h = 4 }, sql = "SELECT sum(all_in_cost) AS all_in FROM cost.databricks_all_in WHERE day >= ${local.month_start} AND ${local.databricks_ws}", unit = "currencyUSD", steps = local.usd_steps },
      { id = 5, type = "stat", title = "AWS share of all-in", description = "The AWS part of this month's all-in cost. ${local.databricks_aws}", grid = { x = 20, y = 0, w = 4, h = 4 }, sql = "SELECT 100 * sum(aws_cost) / nullif(sum(all_in_cost), 0) AS aws_share FROM cost.databricks_all_in WHERE day >= ${local.month_start} AND ${local.databricks_ws}", unit = "percent", steps = local.usd_steps },
    ]

    series = [
      { id = 12, title = "Daily spend by product (list price)", description = "Each UTC day's Databricks list cost, stacked by product (jobs, SQL, all-purpose, …). A day lands about a day late.", grid = { x = 0, y = 7, w = 12, h = 8 }, sql = "SELECT day::timestamp AS time, product AS metric, sum(list_cost) AS value ${local.databricks_range} GROUP BY 1, 2 ORDER BY 1" },
      { id = 13, title = "Serverless vs classic (list price)", description = "Each UTC day's Databricks list cost: serverless compute against classic clusters.", grid = { x = 12, y = 7, w = 12, h = 8 }, sql = "SELECT day::timestamp AS time, CASE WHEN serverless THEN 'serverless' ELSE 'classic' END AS metric, sum(list_cost) AS value ${local.databricks_range} GROUP BY 1, 2 ORDER BY 1" },
      { id = 22, title = "Daily DBUs by product", description = "Each UTC day's Databricks Units, stacked by product.", grid = { x = 0, y = 18, w = 24, h = 8 }, sql = "SELECT day::timestamp AS time, product AS metric, sum(quantity) AS value ${local.databricks_range} AND unit = 'DBU' GROUP BY 1, 2 ORDER BY 1", unit = "suffix: DBU" },
      { id = 42, title = "Daily all-in: Databricks and AWS", description = "Each UTC day's Databricks list cost and the AWS cost tagged to its workspaces, stacked. ${local.databricks_aws}", grid = { x = 0, y = 40, w = 14, h = 8 }, sql = "SELECT day::timestamp AS time, 'Databricks (list price)' AS metric, sum(databricks_cost) AS value FROM cost.databricks_all_in WHERE $__timeFilter(day) AND ${local.databricks_ws} GROUP BY 1 UNION ALL SELECT day::timestamp, 'AWS', sum(aws_cost) FROM cost.databricks_all_in WHERE $__timeFilter(day) AND ${local.databricks_ws} GROUP BY 1 ORDER BY 1" },
    ]

    bars = [
      { id = 32, title = "Month to date by workspace (list price)", description = "This month's Databricks list cost by workspace (by id when its name isn't exported).", grid = { x = 0, y = 29, w = 8, h = 8 }, sql = "SELECT workspace AS metric, sum(list_cost) AS value ${local.databricks_month} GROUP BY 1 ORDER BY 2 DESC" },
      { id = 34, title = "Month to date by project (list price)", description = "This month's Databricks list cost by project: its Project tag, or the workspace's project.", grid = { x = 18, y = 29, w = 6, h = 8 }, sql = "SELECT coalesce(project, '(none)') AS metric, sum(list_cost) AS value ${local.databricks_month} GROUP BY 1 ORDER BY 2 DESC" },
    ]

    tables = [
      { id = 33, title = "Month to date by SKU (list price)", description = "This month's Databricks usage by SKU: its product, whether it's serverless, the DBUs and the list cost.", grid = { x = 8, y = 29, w = 10, h = 8 }, sql = "SELECT sku, product, serverless, sum(quantity) FILTER (WHERE unit = 'DBU') AS dbus, sum(list_cost) AS list_cost ${local.databricks_month} GROUP BY 1, 2, 3 ORDER BY 5 DESC", units = { dbus = "none", list_cost = "currencyUSD" } },
      { id = 43, title = "This month by workspace, all in", description = "Each workspace's Databricks list cost, the AWS cost tagged to it, and both. ${local.databricks_aws}", grid = { x = 14, y = 40, w = 10, h = 8 }, sql = "SELECT workspace, sum(databricks_cost) AS databricks, sum(aws_cost) AS aws, sum(all_in_cost) AS all_in FROM cost.databricks_all_in WHERE day >= ${local.month_start} AND ${local.databricks_ws} GROUP BY 1 ORDER BY 4 DESC", units = { databricks = "currencyUSD", aws = "currencyUSD", all_in = "currencyUSD" } },
    ]

    rows = [
      { id = 10, y = 4, title = "Spend", text = "**Spend.** Databricks list cost by product, and serverless against classic. List price is what's billed: the account pays as it goes." },
      { id = 20, y = 15, title = "DBUs", text = "**DBUs.** Databricks Units by product." },
      { id = 30, y = 26, title = "Where it goes", text = "**Where it goes.** This month by workspace, SKU and project." },
      { id = 40, y = 37, title = "All-in", text = "**All-in.** Databricks plus the AWS it runs on: the AWS rows tagged ${local.databricks_tag} with the workspace's name." },
    ]
  }
}
