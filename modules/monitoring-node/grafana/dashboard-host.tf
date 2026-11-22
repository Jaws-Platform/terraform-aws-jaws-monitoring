# Monitoring node · Host health, in the owner's prog-strength style: stat tiles
# that turn green, yellow or red; time series with dashed warning and critical
# lines (the rules' numbers, from local.lines); rows that open with a text
# panel; a description on every panel; the last 6 hours, refreshed every 30s.
#
# Panels are built from typed spec lists, one builder per panel type, then
# ordered by id. Ids are fixed: the alert rules link to them, and plan 06 adds
# the Pipeline row at 60.

locals {
  prom  = { type = "prometheus", uid = "prometheus" }
  mixed = { type = "datasource", uid = "-- Mixed --" }

  # -------------------------------------------------------------- helpers
  line_targets = {
    for key, l in local.lines : key => [
      for i, sev in ["warning", "critical"] : {
        datasource   = local.prom
        expr         = "vector(${l[sev]})"
        legendFormat = "${l.words[i]} (${l[sev]}${l.unit})"
        refId        = sev
      } if l[sev] != null
    ]
  }

  line_overrides = {
    for key, l in local.lines : key => [
      for i, sev in ["warning", "critical"] : {
        matcher = { id = "byName", options = "${l.words[i]} (${l[sev]}${l.unit})" }
        properties = [
          { id = "color", value = { mode = "fixed", fixedColor = sev == "warning" ? "yellow" : "red" } },
          { id = "custom.lineStyle", value = { fill = "dash", dash = [10, 10] } },
        ]
      } if l[sev] != null
    ]
  }

  threshold_phrases = {
    for key, l in local.lines : key => join(", ", [for sev in ["warning", "critical"] : "${sev} ${l.worse} ${l[sev]}${l.unit}" if l[sev] != null])
  }
  threshold_text = {
    for key, p in local.threshold_phrases : key => "${upper(substr(p, 0, 1))}${substr(p, 1, -1)}: the same numbers as the alert rules."
  }

  steps = {
    for key in ["cpu", "memory", "disk"] : key => [
      { color = "green", value = null },
      { color = "yellow", value = local.lines[key].warning },
      { color = "red", value = local.lines[key].critical },
    ]
  }
  steps_credits = [
    { color = "red", value = null },
    { color = "yellow", value = local.lines.credits.critical },
    { color = "green", value = local.lines.credits.warning },
  ]
  steps_info = [{ color = "blue", value = null }]

  disk_tile = "100 * (1 - node_filesystem_avail_bytes{mountpoint=\"%s\"} / node_filesystem_size_bytes{mountpoint=\"%s\"})"

  # ---------------------------------------------------------------- tiles
  stat_specs = concat(
    [
      { id = 1, title = "CPU", description = "CPU used across all cores, averaged over 10 minutes. ${local.threshold_text.cpu}", grid = { x = 0, y = 0, w = 3, h = 4 }, datasource = local.prom, target = { datasource = local.prom, expr = local.q.cpu, instant = true }, unit = "percent", steps = local.steps.cpu, text_mode = "value", graph = "area", decimals = 1 },
      { id = 2, title = "Memory", description = "Memory in use, averaged over 5 minutes. ${local.threshold_text.memory}", grid = { x = 3, y = 0, w = 3, h = 4 }, datasource = local.prom, target = { datasource = local.prom, expr = local.q.memory, instant = true }, unit = "percent", steps = local.steps.memory, text_mode = "value", graph = "area", decimals = 1 },
      { id = 3, title = "Root disk", description = "Space used on the root volume: the OS, Docker images and the swap file. ${local.threshold_text.disk}", grid = { x = 6, y = 0, w = 3, h = 4 }, datasource = local.prom, target = { datasource = local.prom, expr = format(local.disk_tile, "/", "/"), instant = true }, unit = "percent", steps = local.steps.disk, text_mode = "value", graph = "area", decimals = 1 },
      { id = 4, title = "Data disk", description = "Space used on /data: Prometheus, Postgres, Grafana and Caddy's certificates. ${local.threshold_text.disk}", grid = { x = 9, y = 0, w = 3, h = 4 }, datasource = local.prom, target = { datasource = local.prom, expr = format(local.disk_tile, "/data", "/data"), instant = true }, unit = "percent", steps = local.steps.disk, text_mode = "value", graph = "area", decimals = 1 },
    ],
    [
      for s in [{ id = 5, title = "CPU credits", description = "The instance's CPU credit balance (CloudWatch); it can burst while it has credits. ${local.threshold_text.credits} (${var.thresholds.cpu_credits_percent.warning} % and ${var.thresholds.cpu_credits_percent.critical} % of the ${coalesce(local.credits_max, 0)} a ${var.instance_type} holds).", grid = { x = 12, y = 0, w = 4, h = 4 }, datasource = local.credits_query.datasource, target = local.credits_query, unit = "none", steps = local.steps_credits, text_mode = "value", graph = "area", decimals = 0 }] : s if local.burstable
    ],
    [
      { id = 6, title = "Targets up", description = "Share of Prometheus scrape targets that answered their last scrape; red below 100 %.", grid = { x = 16, y = 0, w = 4, h = 4 }, datasource = local.prom, target = { datasource = local.prom, expr = "100 * avg(up)", instant = true }, unit = "percent", steps = [{ color = "red", value = null }, { color = "green", value = 100 }], text_mode = "value", graph = "none", decimals = 0 },
      { id = 7, title = "Uptime", description = "Time since the node last booted.", grid = { x = 20, y = 0, w = 4, h = 4 }, datasource = local.prom, target = { datasource = local.prom, expr = "time() - node_boot_time_seconds", instant = true }, unit = "s", steps = local.steps_info, text_mode = "value", graph = "none", decimals = 0 },
      { id = 53, title = "Running release", description = "The Amazon Linux 2023 release the node runs.", grid = { x = 8, y = 83, w = 8, h = 8 }, datasource = local.prom, target = { datasource = local.prom, expr = "monitoring_os_release_info", instant = true, legendFormat = "{{release}}" }, unit = "none", steps = local.steps_info, text_mode = "name", graph = "none", decimals = 0 },
      { id = 54, title = "Last boot", description = "When the node last booted.", grid = { x = 16, y = 83, w = 8, h = 8 }, datasource = local.prom, target = { datasource = local.prom, expr = "node_boot_time_seconds * 1000", instant = true }, unit = "dateTimeAsIso", steps = local.steps_info, text_mode = "value", graph = "none", decimals = 0 },
    ],
  )

  stat_panels = [
    for s in local.stat_specs : {
      id          = s.id
      type        = "stat"
      title       = s.title
      description = s.description
      datasource  = s.datasource
      gridPos     = s.grid
      targets     = [merge(s.target, { refId = "A" })]
      options = {
        reduceOptions = { calcs = ["lastNotNull"], fields = "", values = false }
        textMode      = s.text_mode
        colorMode     = "value"
        graphMode     = s.graph
        justifyMode   = "auto"
      }
      fieldConfig = {
        defaults  = { unit = s.unit, decimals = s.decimals, color = { mode = "thresholds" }, thresholds = { mode = "absolute", steps = s.steps } }
        overrides = []
      }
    }
  ]

  # ----------------------------------------------------------- time series
  # lines: a key of local.lines, or null. draw: line or bars.
  series_specs = concat(
    [
      { id = 12, title = "CPU used", description = "CPU used across all cores, averaged over 10 minutes. ${local.threshold_text.cpu}", grid = { x = 0, y = 7, w = 8, h = 8 }, datasource = local.prom, targets = [{ datasource = local.prom, expr = local.q.cpu, legendFormat = "% used" }], unit = "percent", lines = "cpu", draw = "line", stack = false, min = 0, max = 100, no_value = null },
    ],
    [
      for s in [{ id = 13, title = "CPU credit balance", description = "The CPU credit balance (CloudWatch, 5-minute minimum). ${local.threshold_text.credits}", grid = { x = 8, y = 7, w = 8, h = 8 }, datasource = local.mixed, targets = [merge(local.credits_query, { legendFormat = "balance" })], unit = "none", lines = "credits", draw = "line", stack = false, min = 0, max = null, no_value = null }] : s if local.burstable
    ],
    [
      { id = 14, title = "Load", description = "Load average over 1, 5 and 15 minutes, against the number of cores: load above the cores, sustained, means work is waiting.", grid = { x = 16, y = 7, w = 8, h = 8 }, datasource = local.prom, targets = [{ datasource = local.prom, expr = "node_load1", legendFormat = "1m" }, { datasource = local.prom, expr = "node_load5", legendFormat = "5m" }, { datasource = local.prom, expr = "node_load15", legendFormat = "15m" }, { datasource = local.prom, expr = "count(node_cpu_seconds_total{mode=\"idle\"})", legendFormat = "cores" }], unit = "short", lines = null, draw = "line", stack = false, min = 0, max = null, no_value = null },

      { id = 22, title = "Memory used", description = "Memory in use, averaged over 5 minutes. ${local.threshold_text.memory}", grid = { x = 0, y = 18, w = 8, h = 8 }, datasource = local.prom, targets = [{ datasource = local.prom, expr = local.q.memory, legendFormat = "% used" }], unit = "percent", lines = "memory", draw = "line", stack = false, min = 0, max = 100, no_value = null },
      { id = 23, title = "Swap used", description = "Swap in use, averaged over 15 minutes; a little during start-up is expected. ${local.threshold_text.swap}", grid = { x = 8, y = 18, w = 8, h = 8 }, datasource = local.prom, targets = [{ datasource = local.prom, expr = local.q.swap, legendFormat = "% used" }], unit = "percent", lines = "swap", draw = "line", stack = false, min = 0, max = 100, no_value = null },
      { id = 24, title = "OOM kills (10 min)", description = "Processes the kernel killed for lack of memory in the last 10 minutes. ${local.threshold_text.oom}", grid = { x = 16, y = 18, w = 8, h = 8 }, datasource = local.prom, targets = [{ datasource = local.prom, expr = local.q.oom_kills, legendFormat = "kills" }], unit = "short", lines = "oom", draw = "bars", stack = false, min = 0, max = null, no_value = null },
      { id = 25, title = "Memory pressure", description = "Share of time tasks waited for memory (pressure stall information): some = at least one task, full = all of them. Shows \"Not exposed by this kernel\" if the kernel doesn't report it.", grid = { x = 0, y = 26, w = 12, h = 8 }, datasource = local.prom, targets = [{ datasource = local.prom, expr = "100 * rate(node_pressure_memory_waiting_seconds_total[5m])", legendFormat = "some" }, { datasource = local.prom, expr = "100 * rate(node_pressure_memory_stalled_seconds_total[5m])", legendFormat = "full" }], unit = "percent", lines = null, draw = "line", stack = false, min = 0, max = null, no_value = "Not exposed by this kernel" },
      { id = 26, title = "Memory by container", description = "Working-set memory of each container, stacked. Every container has a memory limit.", grid = { x = 12, y = 26, w = 12, h = 8 }, datasource = local.prom, targets = [{ datasource = local.prom, expr = "container_memory_working_set_bytes{name=~\".+\"}", legendFormat = "{{name}}" }], unit = "bytes", lines = null, draw = "line", stack = true, min = 0, max = null, no_value = null },

      { id = 32, title = "Disk used", description = "Space used on each volume. ${local.threshold_text.disk}", grid = { x = 0, y = 37, w = 8, h = 8 }, datasource = local.prom, targets = [{ datasource = local.prom, expr = local.q.disk, legendFormat = "{{mountpoint}}" }], unit = "percent", lines = "disk", draw = "line", stack = false, min = 0, max = 100, no_value = null },
      { id = 33, title = "Days until full", description = "Days until each volume is full at its last 24 hours' growth; a volume that isn't growing isn't shown. ${local.threshold_text.disk_full}", grid = { x = 8, y = 37, w = 8, h = 8 }, datasource = local.prom, targets = [{ datasource = local.prom, expr = local.q.disk_full_days, legendFormat = "{{mountpoint}}" }], unit = "d", lines = "disk_full", draw = "line", stack = false, min = 0, max = null, no_value = "Not filling up" },
      { id = 34, title = "Inodes used", description = "Inodes used on each volume. ${local.threshold_text.inodes}", grid = { x = 16, y = 37, w = 8, h = 8 }, datasource = local.prom, targets = [{ datasource = local.prom, expr = local.q.inodes, legendFormat = "{{mountpoint}}" }], unit = "percent", lines = "inodes", draw = "line", stack = false, min = 0, max = 100, no_value = null },
      { id = 35, title = "Prometheus size vs its cap", description = "Prometheus's storage against its size cap (prometheus_retention.size_gb). At the cap it drops its oldest data; the line (${local.lines.prom_size.warning}%) is where History kept starts to watch.", grid = { x = 0, y = 45, w = 8, h = 8 }, datasource = local.prom, targets = [{ datasource = local.prom, expr = local.q.prometheus_size, legendFormat = "% of the cap" }], unit = "percent", lines = "prom_size", draw = "line", stack = false, min = 0, max = 100, no_value = null },
      { id = 36, title = "Postgres size", description = "Size of each Postgres database.", grid = { x = 8, y = 45, w = 8, h = 8 }, datasource = local.prom, targets = [{ datasource = local.prom, expr = "pg_database_size_bytes", legendFormat = "{{datname}}" }], unit = "bytes", lines = null, draw = "line", stack = false, min = 0, max = null, no_value = null },
      { id = 37, title = "Disk I/O", description = "Bytes read and written per second, all disks.", grid = { x = 16, y = 45, w = 8, h = 8 }, datasource = local.prom, targets = [{ datasource = local.prom, expr = "sum(rate(node_disk_read_bytes_total[5m]))", legendFormat = "read" }, { datasource = local.prom, expr = "sum(rate(node_disk_written_bytes_total[5m]))", legendFormat = "written" }], unit = "Bps", lines = null, draw = "line", stack = false, min = 0, max = null, no_value = null },
      { id = 38, title = "History kept", description = "How many days of metrics Prometheus holds. It warns only while Prometheus is above ${local.lines.prom_size.warning}% of its size cap and keeps fewer than ${local.lines.history.warning} days, which is when the cap is costing history.", grid = { x = 0, y = 53, w = 8, h = 8 }, datasource = local.prom, targets = [{ datasource = local.prom, expr = local.q.prometheus_history_days, legendFormat = "days kept" }], unit = "d", lines = "history", draw = "line", stack = false, min = 0, max = null, no_value = null },

      { id = 42, title = "Targets up", description = "Each scrape target: 1 when its last scrape worked, 0 when it didn't. Critical when a target stays down for 2 minutes.", grid = { x = 0, y = 64, w = 8, h = 8 }, datasource = local.prom, targets = [{ datasource = local.prom, expr = local.q.up, legendFormat = "{{job}}" }], unit = "short", lines = "up", draw = "line", stack = false, min = 0, max = 1, no_value = null },
      { id = 43, title = "Container restarts (15 min)", description = "Times Docker restarted each container in the last 15 minutes; a config change that recreates a container isn't one. ${local.threshold_text.restarts}", grid = { x = 8, y = 64, w = 8, h = 8 }, datasource = local.prom, targets = [{ datasource = local.prom, expr = local.q.restarts, legendFormat = "{{name}}" }], unit = "short", lines = "restarts", draw = "line", stack = false, min = 0, max = null, no_value = null },
      { id = 44, title = "CPU by container", description = "CPU each container uses, in cores.", grid = { x = 16, y = 64, w = 8, h = 8 }, datasource = local.prom, targets = [{ datasource = local.prom, expr = "rate(container_cpu_usage_seconds_total{name=~\".+\"}[5m])", legendFormat = "{{name}}" }], unit = "short", lines = null, draw = "line", stack = false, min = 0, max = null, no_value = null },
    ],
    [
      for s in [
        { id = 45, title = "TLS days left", description = "Days until the public certificate expires; Caddy renews it about 30 days ahead. ${local.threshold_text.tls}", grid = { x = 0, y = 72, w = 8, h = 8 }, datasource = local.prom, targets = [{ datasource = local.prom, expr = local.q.tls_days, legendFormat = "days left" }], unit = "d", lines = "tls", draw = "line", stack = false, min = 0, max = null, no_value = null },
        { id = 46, title = "HTTPS probe", description = "Whether the public HTTPS address answered the last probe (1) or not (0).", grid = { x = 8, y = 72, w = 8, h = 8 }, datasource = local.prom, targets = [{ datasource = local.prom, expr = "probe_success", legendFormat = "{{instance}}" }], unit = "short", lines = null, draw = "line", stack = false, min = 0, max = 1, no_value = null },
      ] : s if local.served
    ],
    [
      { id = 47, title = "Grafana rule-evaluation failures (10 min)", description = "Alert rules that failed to evaluate in the last 10 minutes: a broken query, or a data source that can't be reached. ${local.threshold_text.eval}", grid = { x = 16, y = 72, w = 8, h = 8 }, datasource = local.prom, targets = [{ datasource = local.prom, expr = local.q.eval_failures, legendFormat = "failures" }], unit = "short", lines = "eval", draw = "line", stack = false, min = 0, max = null, no_value = null },

      { id = 52, title = "Newer AL2023 release available", description = "Days since a newer Amazon Linux 2023 release appeared: time for an AMI bump. ${local.threshold_text.os_release}", grid = { x = 0, y = 83, w = 8, h = 8 }, datasource = local.prom, targets = [{ datasource = local.prom, expr = local.q.os_update_days, legendFormat = "days available" }], unit = "d", lines = "os_release", draw = "line", stack = false, min = 0, max = null, no_value = "Up to date" },
    ],
  )

  series_panels = [
    for s in local.series_specs : {
      id          = s.id
      type        = "timeseries"
      title       = s.title
      description = s.description
      datasource  = s.datasource
      gridPos     = s.grid
      targets = concat(
        [for i, t in s.targets : merge(t, { refId = substr("ABCDEFGH", i, 1) })],
        try(local.line_targets[s.lines], []),
      )
      fieldConfig = {
        defaults = merge(
          {
            unit = s.unit
            custom = {
              drawStyle   = s.draw
              lineWidth   = 1
              fillOpacity = s.stack ? 60 : 10
              showPoints  = "never"
              spanNulls   = false
              stacking    = { mode = s.stack ? "normal" : "none", group = "A" }
            }
          },
          { for k, v in { min = s.min, max = s.max, noValue = s.no_value } : k => v if v != null },
        )
        overrides = try(local.line_overrides[s.lines], [])
      }
      options = {
        legend  = { displayMode = "list", placement = "bottom", showLegend = true }
        tooltip = { mode = "multi", sort = "none" }
      }
    }
  ]

  # ------------------------------------------------------ rows and text
  row_specs = [
    { id = 10, y = 4, title = "CPU" },
    { id = 20, y = 15, title = "Memory" },
    { id = 30, y = 34, title = "Disk" },
    { id = 40, y = 61, title = "Services" },
    { id = 50, y = 80, title = "Patching" },
  ]

  text_specs = [
    { id = 11, y = 5, content = "**Is the node keeping up?** CPU used is a 10-minute average. On a burstable instance type, the credit balance says whether it can keep bursting. The dashed lines are the alert thresholds." },
    { id = 21, y = 16, content = "**Memory.** Every container has a memory limit, and the swap file absorbs start-up spikes (Prometheus replaying its log). An OOM kill means a limit, or the node, is too small." },
    { id = 31, y = 35, content = "**Disk.** The root volume holds the OS, the images and swap; `/data` holds Prometheus, Postgres, Grafana and the certificates, and survives an instance replacement. Days until full projects the last 24 hours. Prometheus drops its oldest data at its size cap; History kept warns only if that cuts history short." },
    { id = 41, y = 62, content = "**Services.** Every scrape target, Docker's restarts of each container (a config change that recreates one isn't a restart), and with a domain, the public HTTPS probe and its certificate." },
    { id = 51, y = 81, content = "**Patching.** Amazon Linux 2023 locks packages to its image's release, so patching is an AMI bump: a PR and a release that replace the instance and keep `/data`." },
  ]

  row_panels  = [for r in local.row_specs : { id = r.id, type = "row", title = r.title, collapsed = false, gridPos = { x = 0, y = r.y, w = 24, h = 1 }, panels = [] }]
  text_panels = [for t in local.text_specs : { id = t.id, type = "text", title = "", transparent = true, gridPos = { x = 0, y = t.y, w = 24, h = 2 }, options = { mode = "markdown", content = t.content } }]

  # ----------------------------------------------------------- dashboard
  host_panels_by_id = merge(
    { for p in local.stat_panels : format("%03d", p.id) => p },
    { for p in local.series_panels : format("%03d", p.id) => p },
    { for p in local.row_panels : format("%03d", p.id) => p },
    { for p in local.text_panels : format("%03d", p.id) => p },
  )

  host_dashboard = {
    uid           = "monitoring-host"
    title         = "Monitoring node · Host health"
    tags          = ["monitoring"]
    timezone      = "browser"
    editable      = false
    graphTooltip  = 1
    schemaVersion = 39
    refresh       = "30s"
    time          = { from = "now-6h", to = "now" }
    panels        = [for k in sort(keys(local.host_panels_by_id)) : local.host_panels_by_id[k]]
  }
}
