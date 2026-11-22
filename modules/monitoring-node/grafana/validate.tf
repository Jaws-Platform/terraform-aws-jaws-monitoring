# The rules validator, ported from prog-strength's validate_rules.py. Grafana
# checks provisioning files only at startup, and one invalid rule is fatal to
# the whole provisioning service: no dashboards, no alerting, found only when
# someone notices Grafana is gone. So every rules file, the module's and the
# caller's, is checked here, and the files output fails the plan if anything
# is wrong (outputs.tf).
#
# Each problem reads "<file> [<group>/<uid>]: <what is wrong>".

locals {
  rule_docs = merge(
    { for path, doc in local.module_alerting : path => doc if can(doc.groups) },
    { for name, yaml in var.extra_alert_rules : local.extra_rules_path[name] => try(yamldecode(yaml), null) },
  )

  groups = flatten([
    for path, doc in local.rule_docs : [
      for g in try(doc.groups, []) : {
        path  = path
        name  = try(tostring(g.name), "<unnamed>")
        group = g
        # Everything Grafana expands from its environment: the group's own
        # fields (its rules are checked one by one below).
        expanded = try(jsonencode({ for k, v in g : k => v if k != "rules" }), "")
      }
    ]
  ])

  rules = flatten([
    for x in local.groups : [
      for r in try(x.group.rules, []) : {
        where = "${x.path} [${x.name}/${try(tostring(r.uid), "<missing-uid>")}]"
        uid   = try(tostring(r.uid), "")
        rule  = r
        refs  = [for d in try(r.data, []) : try(tostring(d.refId), "")]
        # Grafana 13.3 expands $VAR in a rule except in its annotations, its
        # time range and its query model, where a $ is safe.
        expanded = try(jsonencode(merge(
          { for k, v in r : k => v if !contains(["annotations", "data", "relativeTimeRange"], k) },
          { data = [for d in try(r.data, []) : { for k, v in d : k => v if !contains(["model", "relativeTimeRange"], k) }] },
        )), "")
        dashboard = try(tostring(r.annotations.__dashboardUid__), null)
        panel     = try(tostring(r.annotations.__panelId__), null)
      }
    ]
  ])

  dashboard_docs = { for path, json in local.dashboards : path => try(jsondecode(json), null) }

  # Dashboard uid => its panel ids, rows' nested panels included.
  dashboard_panels = {
    for path, d in local.dashboard_docs : try(tostring(d.uid), "") => concat(
      [for p in try(d.panels, []) : try(tostring(p.id), "")],
      flatten([for p in try(d.panels, []) : [for q in try(p.panels, []) : try(tostring(q.id), "")]]),
    )...
  }

  problems = concat(
    [for name, yaml in var.extra_alert_rules : "${local.extra_rules_path[name]}: not valid YAML" if try(yamldecode(yaml), null) == null],

    [for x in local.rules : "${x.where}: missing required field uid" if x.uid == ""],
    [for x in local.rules : "${x.where}: missing required field title" if trimspace(try(tostring(x.rule.title), "")) == ""],
    [for x in local.rules : "${x.where}: missing required field condition" if trimspace(try(tostring(x.rule.condition), "")) == ""],
    [for x in local.rules : "${x.where}: a uid is at most 40 letters, digits, - or _" if x.uid != "" && !can(regex("^[A-Za-z0-9_-]{1,40}$", x.uid))],

    [for uid, paths in { for x in local.rules : x.uid => x.where... if x.uid != "" } : "rule uid ${uid} is defined more than once: ${join(", ", paths)}" if length(paths) > 1],

    [for x in local.rules : "${x.where}: has one of __dashboardUid__ and __panelId__ but not the other; Grafana requires both or neither, and rejects the whole provisioning run otherwise" if(x.dashboard == null) != (x.panel == null)],

    [for x in local.rules : "${x.where}: condition ${try(tostring(x.rule.condition), "")} names no refId in its data (defined: ${join(", ", x.refs)})" if trimspace(try(tostring(x.rule.condition), "")) != "" && !contains(x.refs, try(tostring(x.rule.condition), ""))],

    [for x in local.groups : "${x.path} [${x.name}]: a lone $ in the group, which Grafana expands from its environment; write $$ for a dollar sign" if strcontains(replace(x.expanded, "$$", ""), "$")],
    [for x in local.rules : "${x.where}: a lone $ outside the annotations and the query model, which Grafana expands from its environment; write $$ for a dollar sign" if strcontains(replace(x.expanded, "$$", ""), "$")],

    [for x in local.rules : "${x.where}: links dashboard ${x.dashboard}, which isn't provisioned" if x.dashboard != null && x.panel != null && !contains(keys(local.dashboard_panels), coalesce(x.dashboard, "-"))],
    [for x in local.rules : "${x.where}: links panel ${x.panel} of ${x.dashboard}, which has no such panel" if x.dashboard != null && x.panel != null && contains(keys(local.dashboard_panels), coalesce(x.dashboard, "-")) && !contains(flatten(lookup(local.dashboard_panels, coalesce(x.dashboard, "-"), [])), coalesce(x.panel, "-"))],

    [for x in local.rules : "${x.where}: labels.area must be host, pipeline or cost, because notifications are routed by it" if !contains(["host", "pipeline", "cost"], try(tostring(x.rule.labels.area), ""))],
    [for x in local.rules : "${x.where}: labels.severity must be warning or critical" if !contains(["warning", "critical"], try(tostring(x.rule.labels.severity), ""))],

    [for path, d in local.dashboard_docs : "grafana/dashboards/${path}: not valid JSON" if d == null],
    [for path, d in local.dashboard_docs : "grafana/dashboards/${path}: a dashboard needs a uid and a title" if d != null && (trimspace(try(tostring(d.uid), "")) == "" || trimspace(try(tostring(d.title), "")) == "")],
    [for uid, paths in { for path, d in local.dashboard_docs : try(tostring(d.uid), "") => path... } : "dashboard uid ${uid} is used by more than one file: ${join(", ", paths)}" if uid != "" && length(paths) > 1],
    [for path in keys(var.extra_dashboards) : "grafana/dashboards/${path}: the module renders that path itself" if contains(keys(local.module_dashboards), path)],
  )
}
