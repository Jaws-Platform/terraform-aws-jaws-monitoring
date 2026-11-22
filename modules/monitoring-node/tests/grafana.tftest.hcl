# The Grafana config module: every file under grafana/ in the bundle. It has no
# providers, so these runs plan it directly. The rules validator is a
# precondition on its files output: a rule Grafana would reject at boot (and
# take all of provisioning down with it) fails the plan instead.

variables {
  region            = "us-east-1"
  instance_id       = "i-0123456789abcdef0"
  instance_type     = "t9g.medium"
  domain            = null
  extra_dashboards  = {}
  extra_alert_rules = {}

  # Spec 6.8's defaults. They live once, in the monitoring-node module's
  # thresholds variable; the_default_thresholds_are_the_specs (in
  # monitoring_node.tftest.hcl) pins that copy to the same numbers.
  thresholds = {
    cpu_percent             = { warning = 60, critical = 85 }
    cpu_credits_percent     = { warning = 25, critical = 5 }
    memory_percent          = { warning = 70, critical = 90 }
    swap_percent            = { warning = 25, critical = 75 }
    disk_percent            = { warning = 70, critical = 90 }
    disk_full_days          = { warning = 7, critical = 2 }
    inodes_percent          = { warning = 70, critical = 90 }
    prometheus_size_percent = { warning = 85 }
    prometheus_history_days = { warning = 90 }
    container_restarts      = { warning = 1, critical = 3 }
    tls_days                = { warning = 14, critical = 3 }
    os_release_update_days  = { warning = 7 }
  }
}

run "it_provisions_both_data_sources_and_prunes_removed_ones" {
  command = plan

  module {
    source = "./grafana"
  }

  assert {
    condition     = yamldecode(output.files["grafana/provisioning/datasources/datasources.yaml"]).prune == true
    error_message = "a data source removed from the file is removed from Grafana"
  }

  assert {
    condition     = [for d in yamldecode(output.files["grafana/provisioning/datasources/datasources.yaml"]).datasources : "${d.uid}:${try(d.isDefault, false)}"] == ["prometheus:true", "cloudwatch:false"]
    error_message = "Prometheus (the default) and CloudWatch are provisioned"
  }

  assert {
    condition     = one([for d in yamldecode(output.files["grafana/provisioning/datasources/datasources.yaml"]).datasources : d.jsonData.defaultRegion if d.uid == "cloudwatch"]) == "us-east-1"
    error_message = "CloudWatch reads the node's region"
  }
}

run "grafana_finds_every_provisioning_folder_it_reads" {
  command = plan

  module {
    source = "./grafana"
  }

  assert {
    condition     = yamldecode(output.files["grafana/provisioning/plugins/plugins.yaml"]) == { apiVersion = 1, apps = [] }
    error_message = "the node's provisioning mount hides the image's own folders; without plugins/ Grafana logs an error at every start"
  }
}

run "dashboards_follow_their_files" {
  command = plan

  module {
    source = "./grafana"
  }

  assert {
    condition     = yamldecode(output.files["grafana/provisioning/dashboards/dashboards.yaml"]).providers[0].disableDeletion == false
    error_message = "a dashboard whose file is gone is deleted from Grafana (with disableDeletion it would stay)"
  }

  assert {
    condition     = yamldecode(output.files["grafana/provisioning/dashboards/dashboards.yaml"]).providers[0].allowUiUpdates == false && yamldecode(output.files["grafana/provisioning/dashboards/dashboards.yaml"]).providers[0].options.foldersFromFilesStructure == true
    error_message = "dashboards are read-only in the UI, and each lands in the folder its directory names"
  }
}

run "extra_dashboards_and_rules_are_provisioned" {
  command = plan

  module {
    source = "./grafana"
  }

  variables {
    extra_dashboards  = { "Extra/extra.json" = file("tests/fixtures/extra-dashboard.json") }
    extra_alert_rules = { smoke = file("tests/fixtures/extra-rule.yaml") }
  }

  assert {
    condition     = output.files["grafana/dashboards/Extra/extra.json"] == file("tests/fixtures/extra-dashboard.json")
    error_message = "an extra dashboard lands in its folder as given"
  }

  assert {
    condition     = jsonencode(jsondecode(output.files["grafana/provisioning/alerting/rules-extra-smoke.json"])) == jsonencode(yamldecode(file("tests/fixtures/extra-rule.yaml")))
    error_message = "an extra rules file is provisioned as JSON with the same content"
  }
}

run "accepts_a_dollar_where_grafana_does_not_expand" {
  command = plan

  module {
    source = "./grafana"
  }

  variables {
    extra_alert_rules = { math = file("tests/fixtures/extra-rule-math.yaml") }
  }

  assert {
    condition     = contains(keys(output.files), "grafana/provisioning/alerting/rules-extra-math.json")
    error_message = "Grafana 13.3 doesn't expand data[].model or annotations, so a math step and a summary may use $"
  }
}

run "rejects_a_rule_linked_to_a_dashboard_but_not_a_panel" {
  command = plan

  module {
    source = "./grafana"
  }

  variables {
    extra_dashboards  = { "Extra/extra.json" = file("tests/fixtures/extra-dashboard.json") }
    extra_alert_rules = { smoke = replace(file("tests/fixtures/extra-rule.yaml"), "          __panelId__: \"1\"\n", "") }
  }

  expect_failures = [output.files]
}

run "rejects_a_duplicate_rule_uid" {
  command = plan

  module {
    source = "./grafana"
  }

  variables {
    extra_dashboards  = { "Extra/extra.json" = file("tests/fixtures/extra-dashboard.json") }
    extra_alert_rules = { one = file("tests/fixtures/extra-rule.yaml"), two = file("tests/fixtures/extra-rule.yaml") }
  }

  expect_failures = [output.files]
}

run "rejects_a_condition_without_its_query" {
  command = plan

  module {
    source = "./grafana"
  }

  variables {
    extra_dashboards  = { "Extra/extra.json" = file("tests/fixtures/extra-dashboard.json") }
    extra_alert_rules = { smoke = replace(file("tests/fixtures/extra-rule.yaml"), "condition: C", "condition: D") }
  }

  expect_failures = [output.files]
}

run "rejects_a_dollar_grafana_would_expand" {
  command = plan

  module {
    source = "./grafana"
  }

  variables {
    extra_dashboards  = { "Extra/extra.json" = file("tests/fixtures/extra-dashboard.json") }
    extra_alert_rules = { smoke = replace(file("tests/fixtures/extra-rule.yaml"), "title: Extra up", "title: Cost over $5") }
  }

  expect_failures = [output.files]
}

run "rejects_a_link_to_a_missing_panel" {
  command = plan

  module {
    source = "./grafana"
  }

  variables {
    extra_dashboards  = { "Extra/extra.json" = file("tests/fixtures/extra-dashboard.json") }
    extra_alert_rules = { smoke = replace(file("tests/fixtures/extra-rule.yaml"), "__panelId__: \"1\"", "__panelId__: \"99\"") }
  }

  expect_failures = [output.files]
}

run "rejects_a_rule_without_its_area_and_severity" {
  command = plan

  module {
    source = "./grafana"
  }

  variables {
    extra_dashboards  = { "Extra/extra.json" = file("tests/fixtures/extra-dashboard.json") }
    extra_alert_rules = { smoke = replace(file("tests/fixtures/extra-rule.yaml"), "          area: host\n          severity: critical\n", "          team: platform\n") }
  }

  expect_failures = [output.files]
}

run "rejects_extra_rules_that_are_not_yaml" {
  command = plan

  module {
    source = "./grafana"
  }

  variables {
    extra_alert_rules = { smoke = "groups: [unclosed" }
  }

  expect_failures = [output.files]
}

run "rejects_a_dashboard_without_a_uid" {
  command = plan

  module {
    source = "./grafana"
  }

  variables {
    extra_dashboards = { "Extra/extra.json" = replace(file("tests/fixtures/extra-dashboard.json"), "\"uid\": \"extra-smoke\", ", "") }
  }

  expect_failures = [output.files]
}

run "the_host_dashboard_follows_the_house_style" {
  command = plan

  module {
    source = "./grafana"
  }

  assert {
    condition     = jsondecode(output.files["grafana/dashboards/Monitoring/host.json"]).uid == "monitoring-host" && jsondecode(output.files["grafana/dashboards/Monitoring/host.json"]).title == "Monitoring node · Host health" && jsonencode(jsondecode(output.files["grafana/dashboards/Monitoring/host.json"]).tags) == jsonencode(["monitoring"])
    error_message = "the host dashboard has a fixed uid, since rules link to it"
  }

  assert {
    condition     = jsondecode(output.files["grafana/dashboards/Monitoring/host.json"]).editable == false && jsondecode(output.files["grafana/dashboards/Monitoring/host.json"]).refresh == "30s" && jsonencode(jsondecode(output.files["grafana/dashboards/Monitoring/host.json"]).time) == jsonencode({ from = "now-6h", to = "now" }) && jsondecode(output.files["grafana/dashboards/Monitoring/host.json"]).timezone == "browser" && jsondecode(output.files["grafana/dashboards/Monitoring/host.json"]).graphTooltip == 1 && jsondecode(output.files["grafana/dashboards/Monitoring/host.json"]).schemaVersion == 39
    error_message = "read-only, the last 6 hours, a 30-second refresh"
  }

  assert {
    condition     = length(distinct([for p in jsondecode(output.files["grafana/dashboards/Monitoring/host.json"]).panels : p.id])) == length(jsondecode(output.files["grafana/dashboards/Monitoring/host.json"]).panels)
    error_message = "panel ids are unique"
  }

  assert {
    condition     = alltrue([for i, p in jsondecode(output.files["grafana/dashboards/Monitoring/host.json"]).panels : p.type != "row" || try(jsondecode(output.files["grafana/dashboards/Monitoring/host.json"]).panels[i + 1].type, "") == "text"])
    error_message = "every row opens with a text panel"
  }

  assert {
    condition     = alltrue([for p in jsondecode(output.files["grafana/dashboards/Monitoring/host.json"]).panels : contains(["row", "text"], p.type) || trimspace(try(p.description, "")) != ""])
    error_message = "every panel has a description"
  }
}

run "tiles_and_lines_use_the_thresholds" {
  command = plan

  module {
    source = "./grafana"
  }

  variables {
    thresholds = merge(var.thresholds, { cpu_percent = { warning = 50, critical = 80 } })
  }

  assert {
    condition     = jsonencode(one([for p in jsondecode(output.files["grafana/dashboards/Monitoring/host.json"]).panels : p if p.id == 1]).fieldConfig.defaults.thresholds.steps) == jsonencode([{ color = "green", value = null }, { color = "yellow", value = 50 }, { color = "red", value = 80 }])
    error_message = "the CPU tile turns yellow and red at the thresholds"
  }

  assert {
    condition     = contains([for t in one([for p in jsondecode(output.files["grafana/dashboards/Monitoring/host.json"]).panels : p if p.id == 12]).targets : "${t.expr}|${try(t.legendFormat, "")}"], "vector(50)|warning (50%)") && contains([for t in one([for p in jsondecode(output.files["grafana/dashboards/Monitoring/host.json"]).panels : p if p.id == 12]).targets : "${t.expr}|${try(t.legendFormat, "")}"], "vector(80)|critical (80%)")
    error_message = "CPU used draws the warning and critical lines at the thresholds"
  }

  assert {
    condition     = length(one([for p in jsondecode(output.files["grafana/dashboards/Monitoring/host.json"]).panels : p if p.id == 12]).fieldConfig.overrides) == 2 && alltrue([for o in one([for p in jsondecode(output.files["grafana/dashboards/Monitoring/host.json"]).panels : p if p.id == 12]).fieldConfig.overrides : one([for pr in o.properties : pr.value.fill if pr.id == "custom.lineStyle"]) == "dash"])
    error_message = "the threshold lines are dashed"
  }

  assert {
    condition     = strcontains(one([for p in jsondecode(output.files["grafana/dashboards/Monitoring/host.json"]).panels : p if p.id == 12]).description, "50") && strcontains(one([for p in jsondecode(output.files["grafana/dashboards/Monitoring/host.json"]).panels : p if p.id == 12]).description, "80")
    error_message = "the description states the thresholds"
  }
}

run "credit_panels_need_a_burstable_type" {
  command = plan

  module {
    source = "./grafana"
  }

  assert {
    condition     = length([for p in jsondecode(output.files["grafana/dashboards/Monitoring/host.json"]).panels : p if contains([5, 13], p.id)]) == 2
    error_message = "a t9g.medium has the credit tile and panel"
  }

  assert {
    condition     = contains([for t in one([for p in jsondecode(output.files["grafana/dashboards/Monitoring/host.json"]).panels : p if p.id == 13]).targets : try(t.expr, "")], "vector(144)") && contains([for t in one([for p in jsondecode(output.files["grafana/dashboards/Monitoring/host.json"]).panels : p if p.id == 13]).targets : try(t.expr, "")], "vector(28.8)")
    error_message = "the credit lines are 25 % and 5 % of a t9g.medium's 576"
  }

  assert {
    condition     = contains(flatten([for t in one([for p in jsondecode(output.files["grafana/dashboards/Monitoring/host.json"]).panels : p if p.id == 13]).targets : try(t.dimensions.InstanceId, [])]), "i-0123456789abcdef0")
    error_message = "the credit balance is this instance's"
  }
}

run "credit_panels_need_a_burstable_type_unlike_m7g" {
  command = plan

  module {
    source = "./grafana"
  }

  variables {
    instance_type = "m7g.medium"
  }

  assert {
    condition     = length([for p in jsondecode(output.files["grafana/dashboards/Monitoring/host.json"]).panels : p if contains([5, 13], p.id)]) == 0
    error_message = "a type without CPU credits has no credit panels"
  }
}

run "credit_lines_scale_with_the_type" {
  command = plan

  module {
    source = "./grafana"
  }

  variables {
    instance_type = "t3.large"
  }

  assert {
    condition     = contains([for t in one([for p in jsondecode(output.files["grafana/dashboards/Monitoring/host.json"]).panels : p if p.id == 13]).targets : try(t.expr, "")], "vector(216)") && contains([for t in one([for p in jsondecode(output.files["grafana/dashboards/Monitoring/host.json"]).panels : p if p.id == 13]).targets : try(t.expr, "")], "vector(43.2)")
    error_message = "a t3.large holds 864 credits"
  }
}

run "tls_panels_need_a_domain" {
  command = plan

  module {
    source = "./grafana"
  }

  assert {
    condition     = length([for p in jsondecode(output.files["grafana/dashboards/Monitoring/host.json"]).panels : p if contains([45, 46], p.id)]) == 0
    error_message = "without a domain there is no certificate or probe to show"
  }
}

run "tls_panels_come_with_a_domain" {
  command = plan

  module {
    source = "./grafana"
  }

  variables {
    domain = "grafana.example.com"
  }

  assert {
    condition     = length([for p in jsondecode(output.files["grafana/dashboards/Monitoring/host.json"]).panels : p if contains([45, 46], p.id)]) == 2
    error_message = "with a domain, the TLS and probe panels"
  }
}

run "every_panel_query_is_plain_promql" {
  command = plan

  module {
    source = "./grafana"
  }

  variables {
    domain = "grafana.example.com"
  }

  assert {
    condition     = alltrue([for p in jsondecode(output.files["grafana/dashboards/Monitoring/host.json"]).panels : alltrue([for t in try(p.targets, []) : !strcontains(try(t.expr, ""), "$")])])
    error_message = "no Grafana macros in queries, so promtool can check every one"
  }
}

run "every_rule_mirrors_its_panel" {
  command = plan

  module {
    source = "./grafana"
  }

  variables {
    domain = "grafana.example.com"
  }

  assert {
    condition     = alltrue([for r in flatten([for gr in jsondecode(output.files["grafana/provisioning/alerting/rules-host.json"]).groups : gr.rules]) : r.annotations.__dashboardUid__ == "monitoring-host" && length([for p in jsondecode(output.files["grafana/dashboards/Monitoring/host.json"]).panels : p if tostring(p.id) == r.annotations.__panelId__]) == 1])
    error_message = "every rule links a panel of the host dashboard"
  }

  assert {
    condition = alltrue([
      for r in flatten([for gr in jsondecode(output.files["grafana/provisioning/alerting/rules-host.json"]).groups : gr.rules]) : one([for d in r.data : d.datasourceUid if d.refId == "A"]) != "prometheus" || contains(
        [for t in one([for p in jsondecode(output.files["grafana/dashboards/Monitoring/host.json"]).panels : p if tostring(p.id) == r.annotations.__panelId__]).targets : try(t.expr, "")],
        split(" and on() (", one([for d in r.data : d.model.expr if d.refId == "A"]))[0]
      )
    ])
    error_message = "a Prometheus rule's panel plots exactly what the rule evaluates (before its guard, if it has one)"
  }

  assert {
    condition = alltrue([
      for r in flatten([for gr in jsondecode(output.files["grafana/provisioning/alerting/rules-host.json"]).groups : gr.rules]) : contains(
        [for t in one([for p in jsondecode(output.files["grafana/dashboards/Monitoring/host.json"]).panels : p if tostring(p.id) == r.annotations.__panelId__]).targets : try(t.expr, "")],
        "vector(${one([for d in r.data : d.model.conditions[0].evaluator.params[0] if d.refId == "C"]) + (contains(["host-container-restarts-warning", "host-container-restarts-critical", "host-oom-kill-critical", "host-target-down-critical", "host-rule-eval-failures-warning"], r.uid) ? 0.5 : 0)})"
      )
    ])
    error_message = "a rule's panel draws its threshold as a dashed line (a whole-number count at the number)"
  }
}

run "every_rule_mirrors_its_panel_with_overrides" {
  command = plan

  module {
    source = "./grafana"
  }

  variables {
    domain     = "grafana.example.com"
    thresholds = merge(var.thresholds, { cpu_percent = { warning = 50, critical = 80 }, disk_full_days = { warning = 10, critical = 3 }, container_restarts = { warning = 2, critical = 5 } })
  }

  assert {
    condition     = alltrue([for r in flatten([for gr in jsondecode(output.files["grafana/provisioning/alerting/rules-host.json"]).groups : gr.rules]) : r.annotations.__dashboardUid__ == "monitoring-host" && length([for p in jsondecode(output.files["grafana/dashboards/Monitoring/host.json"]).panels : p if tostring(p.id) == r.annotations.__panelId__]) == 1])
    error_message = "every rule links a panel of the host dashboard"
  }

  assert {
    condition = alltrue([
      for r in flatten([for gr in jsondecode(output.files["grafana/provisioning/alerting/rules-host.json"]).groups : gr.rules]) : one([for d in r.data : d.datasourceUid if d.refId == "A"]) != "prometheus" || contains(
        [for t in one([for p in jsondecode(output.files["grafana/dashboards/Monitoring/host.json"]).panels : p if tostring(p.id) == r.annotations.__panelId__]).targets : try(t.expr, "")],
        split(" and on() (", one([for d in r.data : d.model.expr if d.refId == "A"]))[0]
      )
    ])
    error_message = "a Prometheus rule's panel plots exactly what the rule evaluates (before its guard, if it has one)"
  }

  assert {
    condition = alltrue([
      for r in flatten([for gr in jsondecode(output.files["grafana/provisioning/alerting/rules-host.json"]).groups : gr.rules]) : contains(
        [for t in one([for p in jsondecode(output.files["grafana/dashboards/Monitoring/host.json"]).panels : p if tostring(p.id) == r.annotations.__panelId__]).targets : try(t.expr, "")],
        "vector(${one([for d in r.data : d.model.conditions[0].evaluator.params[0] if d.refId == "C"]) + (contains(["host-container-restarts-warning", "host-container-restarts-critical", "host-oom-kill-critical", "host-target-down-critical", "host-rule-eval-failures-warning"], r.uid) ? 0.5 : 0)})"
      )
    ])
    error_message = "a rule's panel draws its threshold as a dashed line (a whole-number count at the number)"
  }

  assert {
    condition     = one([for d in one([for r in flatten([for gr in jsondecode(output.files["grafana/provisioning/alerting/rules-host.json"]).groups : gr.rules]) : r if r.uid == "host-cpu-warning"]).data : d.model.conditions[0].evaluator.params[0] if d.refId == "C"]) == 50 && one([for d in one([for r in flatten([for gr in jsondecode(output.files["grafana/provisioning/alerting/rules-host.json"]).groups : gr.rules]) : r if r.uid == "host-cpu-critical"]).data : d.model.conditions[0].evaluator.params[0] if d.refId == "C"]) == 80 && one([for d in one([for r in flatten([for gr in jsondecode(output.files["grafana/provisioning/alerting/rules-host.json"]).groups : gr.rules]) : r if r.uid == "host-disk-full-warning"]).data : d.model.conditions[0].evaluator.params[0] if d.refId == "C"]) == 10 && one([for d in one([for r in flatten([for gr in jsondecode(output.files["grafana/provisioning/alerting/rules-host.json"]).groups : gr.rules]) : r if r.uid == "host-container-restarts-critical"]).data : d.model.conditions[0].evaluator.params[0] if d.refId == "C"]) == 4.5
    error_message = "overridden thresholds reach the rules"
  }
}

run "rules_pair_and_carry_area_and_severity" {
  command = plan

  module {
    source = "./grafana"
  }

  assert {
    condition     = alltrue([for r in flatten([for gr in jsondecode(output.files["grafana/provisioning/alerting/rules-host.json"]).groups : gr.rules]) : can(regex("^host-[a-z-]+-(warning|critical)$", r.uid)) && endswith(r.title, " — ${r.labels.severity}") && endswith(r.uid, "-${r.labels.severity}")])
    error_message = "uids are host-<key>-<severity>, and titles end with the severity"
  }

  assert {
    condition     = alltrue([for r in flatten([for gr in jsondecode(output.files["grafana/provisioning/alerting/rules-host.json"]).groups : gr.rules]) : jsonencode(r.labels) == jsonencode({ area = "host", severity = r.labels.severity }) && r.condition == "C"])
    error_message = "every rule carries area = host and its severity, and fires on its threshold step C"
  }

  assert {
    condition     = jsonencode([for gr in jsondecode(output.files["grafana/provisioning/alerting/rules-host.json"]).groups : { name = gr.name, folder = gr.folder, interval = gr.interval }]) == jsonencode([{ name = "host", folder = "Monitoring", interval = "1m" }])
    error_message = "one group, host, in the host dashboard's folder, evaluated every minute"
  }
}

run "count_rules_fire_on_the_whole_number" {
  command = plan

  module {
    source = "./grafana"
  }

  assert {
    condition     = one([for d in one([for r in flatten([for gr in jsondecode(output.files["grafana/provisioning/alerting/rules-host.json"]).groups : gr.rules]) : r if r.uid == "host-container-restarts-warning"]).data : d.model.conditions[0].evaluator.params[0] if d.refId == "C"]) == 0.5 && one([for d in one([for r in flatten([for gr in jsondecode(output.files["grafana/provisioning/alerting/rules-host.json"]).groups : gr.rules]) : r if r.uid == "host-container-restarts-critical"]).data : d.model.conditions[0].evaluator.params[0] if d.refId == "C"]) == 2.5
    error_message = "one restart warns and three are critical: increase() extrapolates, so the threshold sits half below"
  }
}

run "the_history_rule_waits_for_the_cap" {
  command = plan

  module {
    source = "./grafana"
  }

  assert {
    condition     = one([for d in one([for r in flatten([for gr in jsondecode(output.files["grafana/provisioning/alerting/rules-host.json"]).groups : gr.rules]) : r if r.uid == "host-prometheus-history-warning"]).data : d.model.conditions[0].evaluator.type if d.refId == "C"]) == "lt" && one([for d in one([for r in flatten([for gr in jsondecode(output.files["grafana/provisioning/alerting/rules-host.json"]).groups : gr.rules]) : r if r.uid == "host-prometheus-history-warning"]).data : d.model.conditions[0].evaluator.params[0] if d.refId == "C"]) == 90
    error_message = "it warns below 90 days of history"
  }

  assert {
    condition     = endswith(one([for d in one([for r in flatten([for gr in jsondecode(output.files["grafana/provisioning/alerting/rules-host.json"]).groups : gr.rules]) : r if r.uid == "host-prometheus-history-warning"]).data : d.model.expr if d.refId == "A"]), "and on() (100 * (prometheus_tsdb_storage_blocks_bytes + prometheus_tsdb_wal_storage_size_bytes + prometheus_tsdb_head_chunks_storage_size_bytes) / prometheus_tsdb_retention_limit_bytes > 85)")
    error_message = "only while Prometheus is at its cap"
  }
}

run "the_history_rule_waits_for_the_cap_as_configured" {
  command = plan

  module {
    source = "./grafana"
  }

  variables {
    thresholds = merge(var.thresholds, { prometheus_size_percent = { warning = 95 }, prometheus_history_days = { warning = 30 } })
  }

  assert {
    condition     = one([for d in one([for r in flatten([for gr in jsondecode(output.files["grafana/provisioning/alerting/rules-host.json"]).groups : gr.rules]) : r if r.uid == "host-prometheus-history-warning"]).data : d.model.conditions[0].evaluator.params[0] if d.refId == "C"]) == 30 && endswith(one([for d in one([for r in flatten([for gr in jsondecode(output.files["grafana/provisioning/alerting/rules-host.json"]).groups : gr.rules]) : r if r.uid == "host-prometheus-history-warning"]).data : d.model.expr if d.refId == "A"]), "> 95)")
    error_message = "both numbers come from the thresholds"
  }
}

run "credit_rules_use_the_types_maximum" {
  command = plan

  module {
    source = "./grafana"
  }

  assert {
    condition     = one([for d in one([for r in flatten([for gr in jsondecode(output.files["grafana/provisioning/alerting/rules-host.json"]).groups : gr.rules]) : r if r.uid == "host-cpu-credits-warning"]).data : d.model.conditions[0].evaluator.type if d.refId == "C"]) == "lt" && one([for d in one([for r in flatten([for gr in jsondecode(output.files["grafana/provisioning/alerting/rules-host.json"]).groups : gr.rules]) : r if r.uid == "host-cpu-credits-warning"]).data : d.model.conditions[0].evaluator.params[0] if d.refId == "C"]) == 144 && one([for d in one([for r in flatten([for gr in jsondecode(output.files["grafana/provisioning/alerting/rules-host.json"]).groups : gr.rules]) : r if r.uid == "host-cpu-credits-critical"]).data : d.model.conditions[0].evaluator.params[0] if d.refId == "C"]) == 28.8
    error_message = "25 % and 5 % of a t9g.medium's 576 credits"
  }

  assert {
    condition     = one([for r in flatten([for gr in jsondecode(output.files["grafana/provisioning/alerting/rules-host.json"]).groups : gr.rules]) : r if r.uid == "host-cpu-credits-warning"]).noDataState == "NoData" && one([for r in flatten([for gr in jsondecode(output.files["grafana/provisioning/alerting/rules-host.json"]).groups : gr.rules]) : r if r.uid == "host-cpu-credits-warning"]).execErrState == "Alerting"
    error_message = "a credit rule that gets no data, or can't reach CloudWatch, says so"
  }

  assert {
    condition     = jsonencode([for d in one([for r in flatten([for gr in jsondecode(output.files["grafana/provisioning/alerting/rules-host.json"]).groups : gr.rules]) : r if r.uid == "host-cpu-credits-warning"]).data : "${d.refId}:${d.datasourceUid}:${try(d.model.type, "")}"]) == jsonencode(["A:cloudwatch:", "B:__expr__:reduce", "C:__expr__:threshold"])
    error_message = "CloudWatch, reduced to its last value, then the threshold"
  }
}

run "credit_rules_use_the_types_maximum_unlike_m7g" {
  command = plan

  module {
    source = "./grafana"
  }

  variables {
    instance_type = "m7g.medium"
  }

  assert {
    condition     = length([for r in flatten([for gr in jsondecode(output.files["grafana/provisioning/alerting/rules-host.json"]).groups : gr.rules]) : r if startswith(r.uid, "host-cpu-credits-")]) == 0 && contains([for d in jsondecode(output.files["grafana/provisioning/alerting/rules-host.json"]).deleteRules : d.uid], "host-cpu-credits-warning") && contains([for d in jsondecode(output.files["grafana/provisioning/alerting/rules-host.json"]).deleteRules : d.uid], "host-cpu-credits-critical")
    error_message = "without CPU credits there are no credit rules, and any earlier ones are deleted"
  }
}

run "switched_off_rules_are_deleted_and_only_those" {
  command = plan

  module {
    source = "./grafana"
  }

  variables {
    domain        = null
    instance_type = "t9g.medium"
  }

  assert {
    condition     = length(setintersection(toset([for r in flatten([for gr in jsondecode(output.files["grafana/provisioning/alerting/rules-host.json"]).groups : gr.rules]) : r.uid]), toset([for d in jsondecode(output.files["grafana/provisioning/alerting/rules-host.json"]).deleteRules : d.uid]))) == 0
    error_message = "a rule is never both rendered and deleted"
  }

  assert {
    condition     = length(setunion(toset([for r in flatten([for gr in jsondecode(output.files["grafana/provisioning/alerting/rules-host.json"]).groups : gr.rules]) : r.uid]), toset([for d in jsondecode(output.files["grafana/provisioning/alerting/rules-host.json"]).deleteRules : d.uid]))) == 23 && length(flatten([for gr in jsondecode(output.files["grafana/provisioning/alerting/rules-host.json"]).groups : gr.rules])) == 21
    error_message = "rendered and deleted together are the 23-uid catalogue; 21 are rendered here"
  }
}

run "switched_off_rules_are_deleted_and_only_those_with_a_domain" {
  command = plan

  module {
    source = "./grafana"
  }

  variables {
    domain        = "grafana.example.com"
    instance_type = "t9g.medium"
  }

  assert {
    condition     = length(setintersection(toset([for r in flatten([for gr in jsondecode(output.files["grafana/provisioning/alerting/rules-host.json"]).groups : gr.rules]) : r.uid]), toset([for d in jsondecode(output.files["grafana/provisioning/alerting/rules-host.json"]).deleteRules : d.uid]))) == 0
    error_message = "a rule is never both rendered and deleted"
  }

  assert {
    condition     = length(setunion(toset([for r in flatten([for gr in jsondecode(output.files["grafana/provisioning/alerting/rules-host.json"]).groups : gr.rules]) : r.uid]), toset([for d in jsondecode(output.files["grafana/provisioning/alerting/rules-host.json"]).deleteRules : d.uid]))) == 23 && length(flatten([for gr in jsondecode(output.files["grafana/provisioning/alerting/rules-host.json"]).groups : gr.rules])) == 23
    error_message = "rendered and deleted together are the 23-uid catalogue; 23 are rendered here"
  }
}

run "switched_off_rules_are_deleted_and_only_those_without_credits" {
  command = plan

  module {
    source = "./grafana"
  }

  variables {
    domain        = null
    instance_type = "m7g.medium"
  }

  assert {
    condition     = length(setintersection(toset([for r in flatten([for gr in jsondecode(output.files["grafana/provisioning/alerting/rules-host.json"]).groups : gr.rules]) : r.uid]), toset([for d in jsondecode(output.files["grafana/provisioning/alerting/rules-host.json"]).deleteRules : d.uid]))) == 0
    error_message = "a rule is never both rendered and deleted"
  }

  assert {
    condition     = length(setunion(toset([for r in flatten([for gr in jsondecode(output.files["grafana/provisioning/alerting/rules-host.json"]).groups : gr.rules]) : r.uid]), toset([for d in jsondecode(output.files["grafana/provisioning/alerting/rules-host.json"]).deleteRules : d.uid]))) == 23 && length(flatten([for gr in jsondecode(output.files["grafana/provisioning/alerting/rules-host.json"]).groups : gr.rules])) == 19
    error_message = "rendered and deleted together are the 23-uid catalogue; 19 are rendered here"
  }
}

run "switched_off_rules_are_deleted_and_only_those_with_a_domain_without_credits" {
  command = plan

  module {
    source = "./grafana"
  }

  variables {
    domain        = "grafana.example.com"
    instance_type = "m7g.medium"
  }

  assert {
    condition     = length(setintersection(toset([for r in flatten([for gr in jsondecode(output.files["grafana/provisioning/alerting/rules-host.json"]).groups : gr.rules]) : r.uid]), toset([for d in jsondecode(output.files["grafana/provisioning/alerting/rules-host.json"]).deleteRules : d.uid]))) == 0
    error_message = "a rule is never both rendered and deleted"
  }

  assert {
    condition     = length(setunion(toset([for r in flatten([for gr in jsondecode(output.files["grafana/provisioning/alerting/rules-host.json"]).groups : gr.rules]) : r.uid]), toset([for d in jsondecode(output.files["grafana/provisioning/alerting/rules-host.json"]).deleteRules : d.uid]))) == 23 && length(flatten([for gr in jsondecode(output.files["grafana/provisioning/alerting/rules-host.json"]).groups : gr.rules])) == 21
    error_message = "rendered and deleted together are the 23-uid catalogue; 21 are rendered here"
  }
}

run "every_rule_waits_at_least_two_minutes" {
  command = plan

  module {
    source = "./grafana"
  }

  variables {
    domain = "grafana.example.com"
  }

  assert {
    condition     = alltrue([for r in flatten([for gr in jsondecode(output.files["grafana/provisioning/alerting/rules-host.json"]).groups : gr.rules]) : endswith(r.for, "m") && tonumber(trimsuffix(r.for, "m")) >= 2])
    error_message = "a Prometheus or Grafana restart during a config change must not post: every rule waits at least 2 minutes"
  }
}
