# The cost dashboards' one builder. Each dashboard file holds its variables
# (local.<board>_vars), its panel specs and rows (local.<board>_board); this
# file turns them into Grafana JSON in the house style (6.7), and into the
# filter its queries share (local.cost_filter.<board>).
#
# A multi-value variable says "All" as '__all' (allValue), and every query
# guards it: ('__all' IN ($v) OR <column> IN ($v)). An empty variable then
# never becomes IN (), and "All" never lists every value.

locals {
  cost_ds       = { type = "grafana-postgresql-datasource", uid = "cost" }
  cost_target   = { datasource = local.cost_ds, editorMode = "code", rawQuery = true, refId = "A" }
  usd_steps     = [{ color = "blue", value = null }]
  percent_steps = [{ color = "green", value = null }, { color = "yellow", value = 80 }, { color = "red", value = 100 }]
  month_start   = "date_trunc('month', cost.now() AT TIME ZONE 'UTC')::date"

  # Board => [{ name, label, query, column, multi = true }]: column is the SQL
  # expression the variable filters.
  cost_board_vars = {
    overview = local.overview_vars
    project  = local.project_vars
  }

  # Board => { uid, title, time, stats, series, bars, tables, pies, rows }.
  cost_boards = {
    overview = local.overview_board
    project  = local.project_board
  }

  cost_filter = {
    for b, vars in local.cost_board_vars : b => join(" AND ", [
      for v in vars : try(v.multi, true)
      ? format("('__all' IN ($%s) OR %s IN ($%s))", v.name, v.column, v.name)
      : format("%s IN ($%s)", v.column, v.name)
    ])
  }

  cost_variables = {
    for b, vars in local.cost_board_vars : b => [
      for v in vars : merge(
        {
          name    = v.name, label = v.label, type = "query", datasource = local.cost_ds, query = v.query, definition = v.query
          refresh = 2, sort = 1, multi = try(v.multi, true), includeAll = try(v.multi, true)
        },
        { for k, value in { allValue = "'__all'" } : k => value if try(v.multi, true) },
        { for k, value in { current = { text = "All", value = "$__all" } } : k => value if try(v.multi, true) },
      )
    ]
  }

  cost_panels = {
    for b, d in local.cost_boards : b => concat(
      [
        for s in try(d.stats, []) : {
          id      = s.id, type = s.type, title = s.title, description = s.description, datasource = local.cost_ds, gridPos = s.grid
          targets = [merge(local.cost_target, { rawSql = s.sql, format = "table" })]
          options = merge(
            { reduceOptions = { calcs = ["lastNotNull"], fields = "/.*/", values = false } },
            s.type == "stat" ? { colorMode = "value", graphMode = "none", textMode = "value", justifyMode = "auto" } : { showThresholdMarkers = true },
          )
          fieldConfig = {
            defaults  = { unit = s.unit, decimals = try(s.decimals, 0), noValue = try(s.no_value, "No data"), color = { mode = "thresholds" }, thresholds = { mode = "absolute", steps = s.steps } }
            overrides = []
          }
        }
      ],
      [
        for s in try(d.series, []) : merge(
          {
            id      = s.id, type = "timeseries", title = s.title, description = s.description, datasource = local.cost_ds, gridPos = s.grid
            targets = [merge(local.cost_target, { rawSql = s.sql, format = "time_series" })]
            options = { legend = { displayMode = "list", placement = "bottom", showLegend = true }, tooltip = { mode = "multi", sort = "desc" } }
            fieldConfig = {
              defaults = {
                unit = try(s.unit, "currencyUSD")
                custom = {
                  drawStyle   = try(s.draw, "bars")
                  fillOpacity = try(s.draw, "bars") == "bars" ? 80 : 10
                  lineWidth   = try(s.draw, "bars") == "bars" ? 1 : 2
                  stacking    = { mode = try(s.stack, true) ? "normal" : "none", group = "A" }
                }
              }
              overrides = try(s.overrides, [])
            }
          },
          { for k, v in { timeFrom = try(s.time_from, null) } : k => v if v != null },
        )
      ],
      [
        for s in try(d.bars, []) : {
          id          = s.id, type = "bargauge", title = s.title, description = s.description, datasource = local.cost_ds, gridPos = s.grid
          targets     = [merge(local.cost_target, { rawSql = s.sql, format = "table" })]
          options     = { reduceOptions = { calcs = ["lastNotNull"], fields = "", values = true }, orientation = "horizontal", displayMode = "basic", showUnfilled = true }
          fieldConfig = { defaults = { unit = try(s.unit, "currencyUSD"), decimals = try(s.decimals, 0), color = { mode = "fixed", fixedColor = "blue" } }, overrides = [] }
        }
      ],
      [
        for s in try(d.tables, []) : {
          id      = s.id, type = "table", title = s.title, description = s.description, datasource = local.cost_ds, gridPos = s.grid
          targets = [merge(local.cost_target, { rawSql = s.sql, format = "table" })]
          options = { showHeader = true, cellHeight = "sm" }
          fieldConfig = {
            defaults = { custom = { align = "auto" } }
            overrides = concat(
              [for field, unit in try(s.units, {}) : { matcher = { id = "byName", options = field }, properties = [{ id = "unit", value = unit }, { id = "decimals", value = 2 }] }],
              [for field, steps in try(s.colour, {}) : { matcher = { id = "byName", options = field }, properties = [
                { id = "thresholds", value = { mode = "absolute", steps = steps } },
                { id = "custom.cellOptions", value = { type = "color-background" } },
              ] }],
              [for field, links in try(s.links, {}) : { matcher = { id = "byName", options = field }, properties = [
                { id = "links", value = [for l in links : { title = l.title, url = l.url }] },
              ] }],
              [for field in try(s.hidden, []) : { matcher = { id = "byName", options = field }, properties = [{ id = "custom.hidden", value = true }] }],
              [for field, mappings in try(s.mappings, {}) : { matcher = { id = "byName", options = field }, properties = [
                { id = "mappings", value = mappings },
                { id = "custom.cellOptions", value = { type = "color-background" } },
              ] }],
            )
          }
        }
      ],
      [
        for s in try(d.pies, []) : {
          id      = s.id, type = "piechart", title = s.title, description = s.description, datasource = local.cost_ds, gridPos = s.grid
          targets = [merge(local.cost_target, { rawSql = s.sql, format = "table" })]
          options = {
            reduceOptions = { calcs = ["lastNotNull"], fields = "", values = true }
            pieType       = "pie"
            legend        = { displayMode = "table", placement = "right", showLegend = true, values = ["value", "percent"] }
            tooltip       = { mode = "single", sort = "none" }
          }
          fieldConfig = { defaults = { unit = try(s.unit, "currencyUSD"), decimals = 2 }, overrides = [] }
        }
      ],
      [for r in d.rows : { id = r.id, type = "row", title = r.title, collapsed = false, gridPos = { x = 0, y = r.y, w = 24, h = 1 }, panels = [] }],
      [for r in d.rows : { id = r.id + 1, type = "text", title = "", transparent = true, gridPos = { x = 0, y = r.y + 1, w = 24, h = 2 }, options = { mode = "markdown", content = r.text } }],
    )
  }

  cost_dashboards = {
    for b, d in local.cost_boards : b => {
      uid           = d.uid
      title         = d.title
      tags          = ["cost"]
      timezone      = "browser"
      editable      = false
      graphTooltip  = 1
      schemaVersion = 39
      refresh       = "30s"
      time          = d.time
      templating    = { list = local.cost_variables[b] }
      panels = [
        for k in sort([for p in local.cost_panels[b] : format("%03d", p.id)]) :
        one([for p in local.cost_panels[b] : p if format("%03d", p.id) == k])
      ]
    }
  }
}
