# Cost · Tasks (with cost): one row per task run and one per campaign, over the
# last 30 days (6.12). Runs come from cost.runs: their records, or their tagged
# cost rows alone. A run's cost is an estimate, marked ~, until its last day is
# complete.

locals {
  tasks_vars = [
    for c in [["project", "Project"], ["campaign", "Campaign"], ["workflow", "Workflow"], ["profile", "Profile"], ["outcome", "Outcome"], ["market", "Market"]] : {
      name  = c[0], label = c[1], column = "coalesce(${c[0]}, '(none)')"
      query = "SELECT DISTINCT coalesce(${c[0]}, '(none)') FROM cost.runs ORDER BY 1"
    }
  ]

  tasks_range    = "FROM cost.runs WHERE $__timeFilter(started_at) AND ${local.cost_filter.tasks}"
  tasks_month    = "FROM cost.runs WHERE (started_at AT TIME ZONE 'UTC')::date >= ${local.month_start} AND ${local.cost_filter.tasks}"
  tasks_campaign = "('__all' IN ($project) OR coalesce(project, '(none)') IN ($project)) AND ('__all' IN ($campaign) OR coalesce(campaign, '(none)') IN ($campaign))"
  tasks_money    = "CASE WHEN estimated THEN '~' ELSE '' END || '$' ||"

  tasks_board = {
    uid   = "cost-tasks"
    title = "Cost · Tasks"
    time  = { from = "now-30d", to = "now" }

    stats = [
      { id = 1, type = "stat", title = "Task spend (month)", description = "The cost of task runs started this month (UTC): billed, or estimated while a run's bill is still arriving.", grid = { x = 0, y = 0, w = 4, h = 4 }, sql = "SELECT sum(cost) AS task_spend ${local.tasks_month}", unit = "currencyUSD", steps = local.usd_steps },
      { id = 2, type = "stat", title = "GPU spend (month)", description = "The same, for runs on instances with accelerators (from their records; runs known only from tags aren't counted).", grid = { x = 4, y = 0, w = 4, h = 4 }, sql = "SELECT sum(cost) AS gpu_spend ${local.tasks_month} AND accelerators > 0", unit = "currencyUSD", steps = local.usd_steps },
      { id = 3, type = "stat", title = "Runs", description = "Runs started in the time range.", grid = { x = 8, y = 0, w = 4, h = 4 }, sql = "SELECT count(*) AS runs ${local.tasks_range}", unit = "none", steps = local.usd_steps },
      { id = 4, type = "stat", title = "GPU-hours", description = "Hours × accelerators of the runs started in the time range.", grid = { x = 12, y = 0, w = 4, h = 4 }, sql = "SELECT sum(gpu_hours) AS gpu_hours ${local.tasks_range}", unit = "none", steps = local.usd_steps, decimals = 1 },
      { id = 5, type = "stat", title = "Interrupted runs' cost", description = "The cost of runs in the time range that were interrupted (spot reclaims): spend that finished nothing.", grid = { x = 16, y = 0, w = 4, h = 4 }, sql = "SELECT sum(cost) AS interrupted ${local.tasks_range} AND outcome = 'interrupted'", unit = "currencyUSD", steps = local.usd_steps },
      { id = 6, type = "stat", title = "Avg cost per run", description = "The average cost of a run started in the time range.", grid = { x = 20, y = 0, w = 4, h = 4 }, sql = "SELECT avg(cost) AS avg_cost ${local.tasks_range}", unit = "currencyUSD", steps = local.usd_steps, decimals = 2 },
    ]

    tables = [
      {
        id          = 12, title = "Campaigns", grid = { x = 0, y = 7, w = 24, h = 8 }
        description = "One row per campaign with a run in the time range, over all its runs. Saved vs on demand is each run's hours at its on-demand price, less what it cost. Click a campaign to filter the dashboard to it."
        sql         = "SELECT campaign AS \"Campaign\", project AS \"Project\", first_run AS \"First run\", last_run AS \"Last run\", runs AS \"Runs\", passed || ' / ' || failed || ' / ' || interrupted AS \"Passed / failed / interrupted\", instance_hours AS \"Instance-hours\", gpu_hours AS \"GPU-hours\", cost AS \"Cost\", '$' || to_char(saved, 'FM999990.00') || ' (' || round(saved_percent::numeric) || ' %)' AS \"Saved vs on demand\", cost_per_passed_run AS \"Cost per passed run\" FROM cost.campaigns WHERE last_run >= $__timeFrom() AND ${local.tasks_campaign} ORDER BY last_run DESC"
        units       = { "Instance-hours" = "none", "GPU-hours" = "none", "Cost" = "currencyUSD", "Cost per passed run" = "currencyUSD" }
        links       = { "Campaign" = [{ title = "Filter the runs to this campaign", url = "/d/cost-tasks/cost-tasks?$${__url_time_range}&$${project:queryparam}&var-campaign=$${__value.raw}" }] }
      },
      {
        id          = 22, title = "Runs", grid = { x = 0, y = 18, w = 24, h = 10 }
        description = "One row per run, newest first (at most 500). Cost is billed, or ~ an estimate (hours × the hourly price paid) until the run's last day is complete. % of ceiling turns yellow at 75 and red at 100. Run, PR and Commit open GitHub."
        sql         = "SELECT started_at AS \"Started\", project AS \"Project\", campaign AS \"Campaign\", workflow AS \"Workflow\", task AS \"Task\", replace(run_id, '-', '·') AS \"Run\", pr AS \"PR\", commit AS \"Commit\", profile AS \"Profile\", instance_type AS \"Instance\", accelerators AS \"GPUs\", market AS \"Market\", zone AS \"Zone\", hours * 3600 AS \"Duration\", outcome AS \"Outcome\", ${local.tasks_money} to_char(cost, 'FM999990.00') AS \"Cost\", ceiling_usd AS \"Ceiling\", ceiling_percent AS \"% of ceiling\", ${local.tasks_money} to_char(cost_per_gpu_hour, 'FM999990.00') AS \"$/GPU-hour\", run_url, pr_url, commit_url ${local.tasks_range} ORDER BY started_at DESC LIMIT 500"
        units       = { "Duration" = "dtdurations", "Ceiling" = "currencyUSD", "% of ceiling" = "percent" }
        colour      = { "% of ceiling" = [{ color = "green", value = null }, { color = "yellow", value = 75 }, { color = "red", value = 100 }] }
        links = {
          "Run"    = [{ title = "GitHub Actions run", url = "$${__data.fields.run_url}" }]
          "PR"     = [{ title = "Pull request", url = "$${__data.fields.pr_url}" }]
          "Commit" = [{ title = "Commit", url = "$${__data.fields.commit_url}" }]
        }
        hidden = ["run_url", "pr_url", "commit_url"]
        mappings = { "Outcome" = [{ type = "value", options = {
          passed      = { color = "green", index = 0, text = "passed" }
          failed      = { color = "red", index = 1, text = "failed" }
          interrupted = { color = "orange", index = 2, text = "interrupted" }
          swept       = { color = "purple", index = 3, text = "swept" }
          running     = { color = "blue", index = 4, text = "running" }
        } }] }
      },
      { id = 33, title = "Totals by project, workflow and task", description = "The runs started in the time range, and their cost, by project, workflow and task.", grid = { x = 14, y = 31, w = 10, h = 8 }, sql = "SELECT project AS \"Project\", workflow AS \"Workflow\", task AS \"Task\", count(*) AS \"Runs\", sum(cost) AS \"Cost\" ${local.tasks_range} GROUP BY 1, 2, 3 ORDER BY 5 DESC", units = { "Cost" = "currencyUSD" } },
    ]

    series = [
      { id = 32, title = "Daily task spend by workflow", description = "The cost of the runs started each UTC day, stacked by workflow.", grid = { x = 0, y = 31, w = 14, h = 8 }, sql = "SELECT date_trunc('day', started_at AT TIME ZONE 'UTC')::timestamp AS time, coalesce(workflow, '(none)') AS metric, sum(cost) AS value ${local.tasks_range} GROUP BY 1, 2 ORDER BY 1" },
    ]

    pies = [
      { id = 42, title = "Spot vs on-demand", description = "The cost of the runs in the time range, by market: the share run on spot.", grid = { x = 0, y = 42, w = 8, h = 8 }, sql = "SELECT coalesce(market, '(unknown)') AS metric, sum(cost) AS value ${local.tasks_range} GROUP BY 1 ORDER BY 2 DESC" },
    ]

    bars = [
      { id = 43, title = "Cost per GPU-hour by instance type", description = "What a GPU-hour cost on each instance type, over the runs in the time range.", grid = { x = 8, y = 42, w = 8, h = 8 }, sql = "SELECT instance_type AS metric, sum(cost) / nullif(sum(gpu_hours), 0) AS value ${local.tasks_range} AND gpu_hours > 0 GROUP BY 1 ORDER BY 2 DESC", decimals = 2 },
      { id = 44, title = "% of ceiling, top 20 runs", description = "The runs in the time range closest to their cost ceiling. Yellow at 75 %, red at 100 %, where the over-ceiling alert fires.", grid = { x = 16, y = 42, w = 8, h = 8 }, sql = "SELECT concat_ws(' ', replace(run_id, '-', '·'), task) AS metric, ceiling_percent AS value ${local.tasks_range} AND ceiling_percent IS NOT NULL ORDER BY 2 DESC LIMIT 20", unit = "percent", steps = [{ color = "green", value = null }, { color = "yellow", value = 75 }, { color = "red", value = 100 }] },
    ]

    rows = [
      { id = 10, y = 4, title = "Campaigns", text = "**Campaigns.** Sets of runs toward one goal, named at launch with `--campaign`. Click one to filter the runs to it." },
      { id = 20, y = 15, title = "Runs", text = "**Runs.** One row per run, newest first. ~ marks an estimate: the bill arrives a day or two after a run." },
      { id = 30, y = 28, title = "By workflow", text = "**By workflow.** Task spend each day by workflow, and totals by project, workflow and task." },
      { id = 40, y = 39, title = "Efficiency", text = "**Efficiency.** Spot against on-demand, what a GPU-hour costs on each instance type, and how close runs come to their ceilings." },
    ]
  }
}
