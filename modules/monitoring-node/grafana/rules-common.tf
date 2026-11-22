# What the host and pipeline rules share: expanding each spec into its
# severities (the catalogue), the common fields, the threshold step, the
# Prometheus and CloudWatch shapes, and one provisioning file per area.

locals {
  # One entry per (rule, severity) the table defines: the catalogue, whether
  # rendered here or deleted.
  rule_specs = concat(
    [for s in local.host_rule_specs : merge(s, { area = "host" })],
    [for s in local.pipeline_rule_specs : merge(s, { area = "pipeline" })],
  )

  rule_instances = flatten([
    for s in local.rule_specs : [
      for sev in [{ name = "warning", value = s.warning }, { name = "critical", value = s.critical }] : {
        uid      = "${s.area}-${s.key}-${sev.name}"
        severity = sev.name
        value    = sev.value
        spec     = s
      } if sev.value != null
    ]
  ])
  rules_rendered = [for x in local.rule_instances : x if x.spec.needed]

  rule_common = {
    for x in local.rules_rendered : x.uid => {
      uid          = x.uid
      title        = "${x.spec.title} — ${x.severity}"
      condition    = "C"
      noDataState  = x.spec.source == "cloudwatch" ? "NoData" : "OK"
      execErrState = "Alerting"
      for          = x.spec.for
      labels       = { area = x.spec.area, severity = x.severity }
      annotations = {
        summary          = strcontains(x.spec.summary, "%v") ? format(x.spec.summary, x.value + x.spec.offset) : x.spec.summary
        __dashboardUid__ = "monitoring-host"
        __panelId__      = tostring(x.spec.panel)
      }
    }
  }

  expr_datasource = { type = "__expr__", uid = "__expr__" }

  threshold_step = {
    for x in local.rules_rendered : x.uid => {
      refId         = "C"
      datasourceUid = "__expr__"
      model = {
        refId      = "C"
        type       = "threshold"
        datasource = local.expr_datasource
        expression = x.spec.source == "cloudwatch" ? "B" : "A"
        conditions = [{ evaluator = { type = x.spec.op, params = [x.value] } }]
      }
    }
  }

  prometheus_rules = {
    for x in local.rules_rendered : x.uid => merge(local.rule_common[x.uid], {
      data = [
        {
          refId             = "A"
          datasourceUid     = "prometheus"
          relativeTimeRange = { from = 600, to = 0 }
          model             = { refId = "A", datasource = local.prom, expr = x.spec.query, instant = true, intervalMs = 1000, maxDataPoints = 43200 }
        },
        local.threshold_step[x.uid],
      ]
    }) if x.spec.source == "prometheus"
  }

  cloudwatch_rules = {
    for x in local.rules_rendered : x.uid => merge(local.rule_common[x.uid], {
      data = [
        {
          refId             = "A"
          datasourceUid     = "cloudwatch"
          relativeTimeRange = { from = 1800, to = 0 }
          model             = merge(local.credits_query, { refId = "A", intervalMs = 1000, maxDataPoints = 43200 })
        },
        {
          refId         = "B"
          datasourceUid = "__expr__"
          model         = { refId = "B", type = "reduce", datasource = local.expr_datasource, expression = "A", reducer = "last", settings = { mode = "dropNN" } }
        },
        local.threshold_step[x.uid],
      ]
    }) if x.spec.source == "cloudwatch"
  }

  rules_by_uid = merge(local.prometheus_rules, local.cloudwatch_rules)

  # One file per area: its group (when it has rules) and the deletion of every
  # catalogue uid it doesn't render.
  rules_files = {
    for area in ["host", "pipeline"] : area => {
      apiVersion = 1
      groups = [
        for rules in [[for x in local.rules_rendered : local.rules_by_uid[x.uid] if x.spec.area == area]] : {
          orgId    = 1
          name     = area
          folder   = "Monitoring"
          interval = "1m"
          rules    = rules
        } if length(rules) > 0
      ]
      deleteRules = [for x in local.rule_instances : { orgId = 1, uid = x.uid } if x.spec.area == area && !x.spec.needed]
    }
  }
}
