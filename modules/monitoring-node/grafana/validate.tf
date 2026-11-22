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
      for g in try([for g in doc.groups : g], []) : {
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
      for r in try([for r in x.group.rules : r], []) : {
        where = "${x.path} [${x.name}/${try(tostring(r.uid), "<missing-uid>")}]"
        uid   = try(tostring(r.uid), "")
        rule  = r
        refs  = try([for d in r.data : try(tostring(d.refId), "")], [])
        # Each query: its refId, its data source, and whether its model is an object.
        queries = try([for d in r.data : { ref = try(tostring(d.refId), ""), source = try(tostring(d.datasourceUid), ""), model = can(keys(d.model)) }], [])
        data_ok = !can(keys(r.data)) && can([for d in r.data : keys(d)]) && try(length(r.data), 0) > 0
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

  # A value is a list of objects (not a string, not a map).
  list_of_objects = { for path, doc in local.rule_docs : path => {
    groups       = !can(doc.groups) || (!can(keys(doc.groups)) && can([for g in doc.groups : keys(g)]))
    delete_rules = !can(doc.deleteRules) || (!can(keys(doc.deleteRules)) && can([for d in doc.deleteRules : keys(d)]))
  } }

  seconds     = { s = 1, m = 60, h = 3600, d = 86400 }
  extra_path  = "grafana/provisioning/alerting/rules-extra-"
  module_uids = [for x in local.rule_instances : x.uid]

  # Dashboard uid => its panel ids, rows' nested panels included.
  dashboard_panels = {
    for path, d in local.dashboard_docs : try(tostring(d.uid), "") => concat(
      [for p in try(d.panels, []) : try(tostring(p.id), "")],
      flatten([for p in try(d.panels, []) : [for q in try(p.panels, []) : try(tostring(q.id), "")]]),
    )...
  }

  problems = concat(
    [for name, yaml in var.extra_alert_rules : "${local.extra_rules_path[name]}: not valid YAML" if try(yamldecode(yaml), null) == null],
    [for name, yaml in var.extra_alert_rules : "${local.extra_rules_path[name]}: not a provisioning document (an object with groups or deleteRules)" if try(yamldecode(yaml), null) != null && !can(keys(yamldecode(yaml)))],
    [for path, ok in local.list_of_objects : "${path}: groups must be a list of rule groups" if !ok.groups],
    [for path, ok in local.list_of_objects : "${path}: deleteRules must be a list of { orgId, uid }" if !ok.delete_rules],

    [for x in local.groups : "${x.path} [${x.name}]: a group needs a name" if trimspace(try(tostring(x.group.name), "")) == ""],
    [for x in local.groups : "${x.path} [${x.name}]: a group needs a folder" if trimspace(try(tostring(x.group.folder), "")) == ""],
    [for x in local.groups : "${x.path} [${x.name}]: interval must be a duration on Grafana's 10-second grid (10s, 1m, 5m, ...); Grafana exits at startup otherwise" if !can(regex("^([0-9]+(s|m|h|d))+$", try(tostring(x.group.interval), ""))) || sum(concat([0], [for m in regexall("([0-9]+)(s|m|h|d)", try(tostring(x.group.interval), "")) : tonumber(m[0]) * local.seconds[m[1]]])) % 10 != 0 || sum(concat([0], [for m in regexall("([0-9]+)(s|m|h|d)", try(tostring(x.group.interval), "")) : tonumber(m[0]) * local.seconds[m[1]]])) == 0],
    [for x in local.groups : "${x.path} [${x.name}]: rules must be a list of rules" if !(can(x.group.rules) && !can(keys(x.group.rules)) && can([for r in x.group.rules : keys(r)]))],

    [for x in local.rules : "${x.where}: missing required field uid" if x.uid == ""],
    [for x in local.rules : "${x.where}: missing required field title" if trimspace(try(tostring(x.rule.title), "")) == ""],
    [for x in local.rules : "${x.where}: missing required field condition" if trimspace(try(tostring(x.rule.condition), "")) == ""],
    [for x in local.rules : "${x.where}: a uid is at most 40 letters, digits, - or _" if x.uid != "" && !can(regex("^[A-Za-z0-9_-]{1,40}$", x.uid))],

    [for uid, paths in { for x in local.rules : x.uid => x.where... if x.uid != "" } : "rule uid ${uid} is defined more than once: ${join(", ", paths)}" if length(paths) > 1],
    [for x in local.rules : "${x.where}: that uid belongs to the module's own rules (which may be deleting it); pick another" if startswith(x.where, local.extra_path) && contains(local.module_uids, x.uid)],

    [for x in local.rules : "${x.where}: for must be a duration like 2m or 1h30m; Grafana exits at startup otherwise" if can(x.rule.for) && !can(regex("^([0-9]+(ms|s|m|h|d|w|y))+$", tostring(x.rule.for)))],
    [for x in local.rules : "${x.where}: noDataState must be OK, NoData, Alerting or KeepLast" if can(x.rule.noDataState) && !contains(["OK", "NoData", "Alerting", "KeepLast"], try(tostring(x.rule.noDataState), "-"))],
    [for x in local.rules : "${x.where}: execErrState must be OK, Error, Alerting or KeepLast" if can(x.rule.execErrState) && !contains(["OK", "Error", "Alerting", "KeepLast"], try(tostring(x.rule.execErrState), "-"))],
    [for x in local.rules : "${x.where}: data must be a non-empty list of queries" if !x.data_ok],
    [for x in local.rules : "${x.where}: every query in data needs a refId, a datasourceUid and a model" if x.data_ok && anytrue([for q in x.queries : trimspace(q.ref) == "" || trimspace(q.source) == "" || !q.model])],

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
