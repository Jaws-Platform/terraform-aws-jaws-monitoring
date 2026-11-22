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
    cpu_percent               = { warning = 60, critical = 85 }
    cpu_credits_percent       = { warning = 25, critical = 5 }
    memory_percent            = { warning = 70, critical = 90 }
    swap_percent              = { warning = 25, critical = 75 }
    disk_percent              = { warning = 70, critical = 90 }
    disk_full_days            = { warning = 7, critical = 2 }
    inodes_percent            = { warning = 70, critical = 90 }
    prometheus_size_percent   = { warning = 85 }
    prometheus_history_days   = { warning = 90 }
    container_restarts        = { warning = 1, critical = 3 }
    tls_days                  = { warning = 14, critical = 3 }
    os_release_update_days    = { warning = 7 }
    normalizer_hours          = { warning = 3, critical = 12 }
    aws_charge_days           = { warning = 3, critical = 5 }
    databricks_delivery_hours = { warning = 36, critical = 60 }
    cost_sync_hours           = { warning = 2, critical = 6 }
    anomaly_ratio             = { warning = 2, critical = 4 }
    untagged_daily_usd        = { warning = 0.5 }
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

run "each_channel_is_a_contact_point_and_each_area_a_route" {
  command = plan

  module {
    source = "./grafana"
  }

  variables {
    slack = { channels = { platform = "/acme/monitoring/slack/platform", costs = "/acme/monitoring/slack/costs" }, routes = { host = "platform", pipeline = "platform", cost = "costs" } }
  }

  assert {
    condition     = jsonencode(sort([for c in jsondecode(output.files["grafana/provisioning/alerting/contact-points.json"]).contactPoints : c.name])) == jsonencode(["slack-costs", "slack-platform"])
    error_message = "one contact point per channel"
  }

  assert {
    condition     = one(one([for c in jsondecode(output.files["grafana/provisioning/alerting/contact-points.json"]).contactPoints : c if c.name == "slack-platform"]).receivers).settings.url == "$SLACK_WEBHOOK_PLATFORM" && one(one([for c in jsondecode(output.files["grafana/provisioning/alerting/contact-points.json"]).contactPoints : c if c.name == "slack-costs"]).receivers).settings.url == "$SLACK_WEBHOOK_COSTS"
    error_message = "each webhook URL comes from Grafana's environment, never from the bundle"
  }

  assert {
    condition     = alltrue([for c in jsondecode(output.files["grafana/provisioning/alerting/contact-points.json"]).contactPoints : one(c.receivers).type == "slack" && one(c.receivers).uid == c.name && one(c.receivers).settings.title == "{{ template \"monitoring.title\" . }}" && one(c.receivers).settings.text == "{{ template \"monitoring.text\" . }}" && one(c.receivers).disableResolveMessage == false])
    error_message = "every channel uses the one template and posts resolved messages too"
  }

  assert {
    condition     = one(jsondecode(output.files["grafana/provisioning/alerting/policies.json"]).policies).receiver == "slack-platform" && jsonencode(one(jsondecode(output.files["grafana/provisioning/alerting/policies.json"]).policies).group_by) == jsonencode(["grafana_folder", "alertname"]) && one(jsondecode(output.files["grafana/provisioning/alerting/policies.json"]).policies).repeat_interval == "4h" && one(jsondecode(output.files["grafana/provisioning/alerting/policies.json"]).policies).group_wait == "30s" && one(jsondecode(output.files["grafana/provisioning/alerting/policies.json"]).policies).group_interval == "5m"
    error_message = "the root policy goes to the host channel, grouped by folder and alertname, repeating every 4 hours"
  }

  assert {
    condition     = length([for r in one(jsondecode(output.files["grafana/provisioning/alerting/policies.json"]).policies).routes : r if r.object_matchers[0][0] == "area"]) == 3 && jsonencode(one([for r in one(jsondecode(output.files["grafana/provisioning/alerting/policies.json"]).policies).routes : r if r.receiver == "slack-costs"]).object_matchers) == jsonencode([["area", "=", "cost"]])
    error_message = "one route per area, each to its channel"
  }

  assert {
    condition     = output.webhook_env == { costs = "SLACK_WEBHOOK_COSTS", platform = "SLACK_WEBHOOK_PLATFORM" }
    error_message = "the node is told which variable carries each channel's webhook"
  }
}

run "one_template_formats_every_message" {
  command = plan

  module {
    source = "./grafana"
  }

  variables {
    slack = { channels = { platform = "/acme/monitoring/slack/platform", costs = "/acme/monitoring/slack/costs" }, routes = { host = "platform", pipeline = "platform", cost = "costs" } }
  }

  assert {
    condition     = length(jsondecode(output.files["grafana/provisioning/alerting/templates.json"]).templates) == 1 && one(jsondecode(output.files["grafana/provisioning/alerting/templates.json"]).templates).name == "monitoring-slack"
    error_message = "one template group formats every message"
  }

  assert {
    condition     = strcontains(one(jsondecode(output.files["grafana/provisioning/alerting/templates.json"]).templates).template, "define \"monitoring.title\"") && strcontains(one(jsondecode(output.files["grafana/provisioning/alerting/templates.json"]).templates).template, "define \"monitoring.text\"") && !strcontains(one(jsondecode(output.files["grafana/provisioning/alerting/templates.json"]).templates).template, "$")
    error_message = "it defines the title and the text, with no $ for Grafana to expand"
  }

  assert {
    condition     = strcontains(one(jsondecode(output.files["grafana/provisioning/alerting/templates.json"]).templates).template, "(ne .Name \"alertname\") (ne .Name \"grafana_folder\") (ne .Name \"severity\")") && strcontains(one(jsondecode(output.files["grafana/provisioning/alerting/templates.json"]).templates).template, ".PanelURL")
    error_message = "the message lists the labels that matter and links the panel"
  }
}

run "without_slack_the_policy_tree_is_reset" {
  command = plan

  module {
    source = "./grafana"
  }

  assert {
    condition     = !contains(keys(output.files), "grafana/provisioning/alerting/contact-points.json") && !contains(keys(output.files), "grafana/provisioning/alerting/templates.json")
    error_message = "without Slack there is nothing to post to"
  }

  assert {
    condition     = jsonencode(jsondecode(output.files["grafana/provisioning/alerting/policies.json"])) == jsonencode({ apiVersion = 1, resetPolicies = [1] })
    error_message = "and Grafana's stored policy tree is reset, so a removed Slack leaves nothing pointing at it"
  }

  assert {
    condition     = output.webhook_env == {}
    error_message = "no webhooks to read"
  }
}

run "rejects_a_for_grafana_cant_parse" {
  command = plan

  module {
    source = "./grafana"
  }

  variables {
    extra_dashboards  = { "Extra/extra.json" = file("tests/fixtures/extra-dashboard.json") }
    extra_alert_rules = { smoke = replace(file("tests/fixtures/extra-rule.yaml"), "        for: 2m", "        for: 5 minutes") }
  }

  expect_failures = [output.files]
}

run "rejects_an_unknown_no_data_state" {
  command = plan

  module {
    source = "./grafana"
  }

  variables {
    extra_dashboards  = { "Extra/extra.json" = file("tests/fixtures/extra-dashboard.json") }
    extra_alert_rules = { smoke = replace(file("tests/fixtures/extra-rule.yaml"), "noDataState: OK", "noDataState: Ok") }
  }

  expect_failures = [output.files]
}

run "rejects_an_unknown_error_state" {
  command = plan

  module {
    source = "./grafana"
  }

  variables {
    extra_dashboards  = { "Extra/extra.json" = file("tests/fixtures/extra-dashboard.json") }
    extra_alert_rules = { smoke = replace(file("tests/fixtures/extra-rule.yaml"), "execErrState: Alerting", "execErrState: Firing") }
  }

  expect_failures = [output.files]
}

run "rejects_an_interval_off_grafanas_10s_grid" {
  command = plan

  module {
    source = "./grafana"
  }

  variables {
    extra_dashboards  = { "Extra/extra.json" = file("tests/fixtures/extra-dashboard.json") }
    extra_alert_rules = { smoke = replace(file("tests/fixtures/extra-rule.yaml"), "    interval: 1m", "    interval: 15s") }
  }

  expect_failures = [output.files]
}

run "rejects_a_group_without_a_folder" {
  command = plan

  module {
    source = "./grafana"
  }

  variables {
    extra_dashboards  = { "Extra/extra.json" = file("tests/fixtures/extra-dashboard.json") }
    extra_alert_rules = { smoke = replace(file("tests/fixtures/extra-rule.yaml"), "    folder: Extra\n", "") }
  }

  expect_failures = [output.files]
}

run "rejects_a_document_that_is_not_one" {
  command = plan

  module {
    source = "./grafana"
  }

  variables {
    extra_dashboards  = { "Extra/extra.json" = file("tests/fixtures/extra-dashboard.json") }
    extra_alert_rules = { smoke = "just a string" }
  }

  expect_failures = [output.files]
}

run "rejects_a_query_without_a_data_source" {
  command = plan

  module {
    source = "./grafana"
  }

  variables {
    extra_dashboards  = { "Extra/extra.json" = file("tests/fixtures/extra-dashboard.json") }
    extra_alert_rules = { smoke = replace(file("tests/fixtures/extra-rule.yaml"), "            datasourceUid: prometheus\n", "") }
  }

  expect_failures = [output.files]
}

run "rejects_a_uid_the_host_rules_own" {
  command = plan

  module {
    source = "./grafana"
  }

  variables {
    extra_dashboards  = { "Extra/extra.json" = file("tests/fixtures/extra-dashboard.json") }
    extra_alert_rules = { smoke = replace(file("tests/fixtures/extra-rule.yaml"), "uid: extra-up-critical", "uid: host-tls-expiry-warning") }
  }

  expect_failures = [output.files]
}

run "the_evaluation_failure_rule_outlasts_its_window" {
  command = plan

  module {
    source = "./grafana"
  }

  assert {
    condition     = tonumber(trimsuffix(one([for r in flatten([for gr in jsondecode(output.files["grafana/provisioning/alerting/rules-host.json"]).groups : gr.rules]) : r.for if r.uid == "host-rule-eval-failures-warning"]), "m")) > 10
    error_message = "a short Prometheus outage leaves failures in the 10-minute window for 10 minutes; the rule must wait longer than that, so only failures that go on fire it"
  }
}

run "the_patch_reminder_repeats_daily" {
  command = plan

  module {
    source = "./grafana"
  }

  variables {
    slack = { channels = { platform = "/acme/monitoring/slack/platform", costs = "/acme/monitoring/slack/costs" }, routes = { host = "platform", pipeline = "platform", cost = "costs" } }
  }

  assert {
    condition     = jsonencode(one(jsondecode(output.files["grafana/provisioning/alerting/policies.json"]).policies).routes[0].object_matchers) == jsonencode([["alertname", "=", "Newer AL2023 release available — warning"]]) && one(jsondecode(output.files["grafana/provisioning/alerting/policies.json"]).policies).routes[0].receiver == "slack-platform" && one(jsondecode(output.files["grafana/provisioning/alerting/policies.json"]).policies).routes[0].repeat_interval == "24h"
    error_message = "a due AMI bump can stay due for days: its reminder goes to the host channel once a day, not every 4 hours"
  }
}

run "with_cost_grafana_reads_the_cost_database" {
  command = plan

  module {
    source = "./grafana"
  }

  variables {
    cost = { providers = ["aws", "databricks"] }
  }

  assert {
    condition     = jsonencode(one([for d in yamldecode(output.files["grafana/provisioning/datasources/datasources.yaml"]).datasources : { type = d.type, url = d.url, user = d.user, database = d.jsonData.database, sslmode = d.jsonData.sslmode, password = d.secureJsonData.password } if d.uid == "cost"])) == jsonencode({ type = "grafana-postgresql-datasource", url = "postgres:5432", user = "cost_reader", database = "cost", sslmode = "disable", password = "$COST_READER_PASSWORD" })
    error_message = "Grafana reads the cost database as its read-only user, with the password from its environment"
  }
}

run "without_cost_there_is_no_cost_database_to_read" {
  command = plan

  module {
    source = "./grafana"
  }

  assert {
    condition     = length([for d in yamldecode(output.files["grafana/provisioning/datasources/datasources.yaml"]).datasources : d if d.uid == "cost"]) == 0
    error_message = "a host-only node has no cost data source"
  }

  assert {
    condition     = jsonencode(yamldecode(output.files["grafana/provisioning/datasources/datasources.yaml"]).deleteDatasources) == jsonencode([{ name = "Cost", orgId = 1 }])
    error_message = "and deletes an earlier one: Grafana 13.3 keeps a data source dropped from the file, prune or not"
  }
}

run "the_pipeline_row_shows_with_cost" {
  command = plan

  module {
    source = "./grafana"
  }

  variables {
    cost = { providers = ["aws", "databricks"] }
  }

  assert {
    condition     = length([for p in jsondecode(output.files["grafana/dashboards/Monitoring/host.json"]).panels : p if p.id >= 60 && p.id <= 68]) == 9 && one([for p in jsondecode(output.files["grafana/dashboards/Monitoring/host.json"]).panels : p.type if p.id == 60]) == "row" && one([for p in jsondecode(output.files["grafana/dashboards/Monitoring/host.json"]).panels : p.type if p.id == 61]) == "text"
    error_message = "with cost, the host dashboard ends with the Pipeline row"
  }
}

run "the_pipeline_row_needs_cost" {
  command = plan

  module {
    source = "./grafana"
  }

  assert {
    condition     = length([for p in jsondecode(output.files["grafana/dashboards/Monitoring/host.json"]).panels : p if p.id >= 60]) == 0
    error_message = "a host-only node has no pipeline to watch"
  }

  assert {
    condition     = length(flatten([for gr in jsondecode(output.files["grafana/provisioning/alerting/rules-pipeline.json"]).groups : gr.rules])) == 0 && length([for d in jsondecode(output.files["grafana/provisioning/alerting/rules-pipeline.json"]).deleteRules : d.uid]) == 11
    error_message = "and every pipeline rule is deleted"
  }
}

run "pipeline_rules_need_their_providers" {
  command = plan

  module {
    source = "./grafana"
  }

  variables {
    cost = { providers = ["aws"] }
  }

  assert {
    condition     = length([for r in flatten([for gr in jsondecode(output.files["grafana/provisioning/alerting/rules-pipeline.json"]).groups : gr.rules]) : r if startswith(r.uid, "pipeline-databricks-stale-")]) == 0 && contains([for d in jsondecode(output.files["grafana/provisioning/alerting/rules-pipeline.json"]).deleteRules : d.uid], "pipeline-databricks-stale-warning") && contains([for d in jsondecode(output.files["grafana/provisioning/alerting/rules-pipeline.json"]).deleteRules : d.uid], "pipeline-databricks-stale-critical")
    error_message = "without Databricks there is no Databricks freshness rule"
  }

  assert {
    condition     = length([for p in jsondecode(output.files["grafana/dashboards/Monitoring/host.json"]).panels : p if p.id == 65]) == 0 && length([for p in jsondecode(output.files["grafana/dashboards/Monitoring/host.json"]).panels : p if p.id == 64]) == 1
    error_message = "nor its panel; AWS keeps its own"
  }
}

run "pipeline_rules_carry_area_pipeline" {
  command = plan

  module {
    source = "./grafana"
  }

  variables {
    cost = { providers = ["aws", "databricks"] }
  }

  assert {
    condition     = length(flatten([for gr in jsondecode(output.files["grafana/provisioning/alerting/rules-pipeline.json"]).groups : gr.rules])) == 11 && alltrue([for r in flatten([for gr in jsondecode(output.files["grafana/provisioning/alerting/rules-pipeline.json"]).groups : gr.rules]) : r.labels.area == "pipeline" && r.annotations.__dashboardUid__ == "monitoring-host" && startswith(r.uid, "pipeline-")])
    error_message = "all 11 pipeline rules route by area pipeline and link the host dashboard"
  }

  assert {
    condition     = jsonencode([for gr in jsondecode(output.files["grafana/provisioning/alerting/rules-pipeline.json"]).groups : { name = gr.name, folder = gr.folder, interval = gr.interval }]) == jsonencode([{ name = "pipeline", folder = "Monitoring", interval = "1m" }]) && length([for d in jsondecode(output.files["grafana/provisioning/alerting/rules-pipeline.json"]).deleteRules : d.uid]) == 0
    error_message = "in their own group, with nothing deleted"
  }
}

run "the_task_run_rules_fire_on_any_overrun" {
  command = plan

  module {
    source = "./grafana"
  }

  variables {
    cost = { providers = ["aws", "databricks"] }
  }

  assert {
    condition     = one([for d in one([for r in flatten([for gr in jsondecode(output.files["grafana/provisioning/alerting/rules-pipeline.json"]).groups : gr.rules]) : r if r.uid == "pipeline-task-run-overdue-critical"]).data : d.model.conditions[0].evaluator.params[0] if d.refId == "C"]) == 0 && one([for d in one([for r in flatten([for gr in jsondecode(output.files["grafana/provisioning/alerting/rules-pipeline.json"]).groups : gr.rules]) : r if r.uid == "pipeline-task-run-over-ceiling-critical"]).data : d.model.conditions[0].evaluator.params[0] if d.refId == "C"]) == 0
    error_message = "a possibly leaked run, or one over its ceiling, is critical at once"
  }

  assert {
    condition     = alltrue([for id in [66, 67] : contains([for t in one([for p in jsondecode(output.files["grafana/dashboards/Monitoring/host.json"]).panels : p if p.id == id]).targets : try(t.expr, "")], "vector(0)")])
    error_message = "their panels draw the line at 0"
  }
}

run "every_pipeline_rule_mirrors_its_panel" {
  command = plan

  module {
    source = "./grafana"
  }

  variables {
    cost       = { providers = ["aws", "databricks"] }
    thresholds = merge(var.thresholds, { cost_sync_hours = { warning = 1, critical = 4 } })
  }

  assert {
    condition     = alltrue([for r in flatten([for gr in jsondecode(output.files["grafana/provisioning/alerting/rules-pipeline.json"]).groups : gr.rules]) : length([for p in jsondecode(output.files["grafana/dashboards/Monitoring/host.json"]).panels : p if tostring(p.id) == r.annotations.__panelId__]) == 1])
    error_message = "every pipeline rule links a panel of the host dashboard"
  }

  assert {
    condition = alltrue([
      for r in flatten([for gr in jsondecode(output.files["grafana/provisioning/alerting/rules-pipeline.json"]).groups : gr.rules]) : contains(
        [for t in one([for p in jsondecode(output.files["grafana/dashboards/Monitoring/host.json"]).panels : p if tostring(p.id) == r.annotations.__panelId__]).targets : try(t.expr, "")],
        one([for d in r.data : d.model.expr if d.refId == "A"])
      )
    ])
    error_message = "a pipeline rule's panel plots exactly what the rule evaluates"
  }

  assert {
    condition = alltrue([
      for r in flatten([for gr in jsondecode(output.files["grafana/provisioning/alerting/rules-pipeline.json"]).groups : gr.rules]) : contains(
        [for t in one([for p in jsondecode(output.files["grafana/dashboards/Monitoring/host.json"]).panels : p if tostring(p.id) == r.annotations.__panelId__]).targets : try(t.expr, "")],
        "vector(${one([for d in r.data : d.model.conditions[0].evaluator.params[0] if d.refId == "C"]) + (contains(["pipeline-normalizer-failed-critical"], r.uid) ? 0.5 : 0)})"
      )
    ])
    error_message = "and draws its threshold as a dashed line"
  }

  assert {
    condition     = one([for d in one([for r in flatten([for gr in jsondecode(output.files["grafana/provisioning/alerting/rules-pipeline.json"]).groups : gr.rules]) : r if r.uid == "pipeline-cost-sync-late-warning"]).data : d.model.conditions[0].evaluator.params[0] if d.refId == "C"]) == 1 && one([for d in one([for r in flatten([for gr in jsondecode(output.files["grafana/provisioning/alerting/rules-pipeline.json"]).groups : gr.rules]) : r if r.uid == "pipeline-cost-sync-late-critical"]).data : d.model.conditions[0].evaluator.params[0] if d.refId == "C"]) == 4
    error_message = "overridden thresholds reach the pipeline rules"
  }
}

run "every_pipeline_rule_waits_at_least_two_minutes" {
  command = plan

  module {
    source = "./grafana"
  }

  variables {
    cost = { providers = ["aws", "databricks"] }
  }

  assert {
    condition     = alltrue([for r in flatten([for gr in jsondecode(output.files["grafana/provisioning/alerting/rules-pipeline.json"]).groups : gr.rules]) : endswith(r.for, "m") && tonumber(trimsuffix(r.for, "m")) >= 2])
    error_message = "no pipeline rule fires on a single evaluation"
  }
}

run "rejects_a_uid_the_pipeline_rules_own" {
  command = plan

  module {
    source = "./grafana"
  }

  variables {
    extra_dashboards  = { "Extra/extra.json" = file("tests/fixtures/extra-dashboard.json") }
    extra_alert_rules = { smoke = replace(file("tests/fixtures/extra-rule.yaml"), "uid: extra-up-critical", "uid: pipeline-cost-sync-late-warning") }
  }

  expect_failures = [output.files]
}

run "an_over_ceiling_run_posts_once_a_week" {
  command = plan

  module {
    source = "./grafana"
  }

  variables {
    cost  = { providers = ["aws"] }
    slack = { channels = { platform = "/acme/monitoring/slack/platform", costs = "/acme/monitoring/slack/costs" }, routes = { host = "platform", pipeline = "costs" } }
  }

  assert {
    condition     = length([for r in one(jsondecode(output.files["grafana/provisioning/alerting/policies.json"]).policies).routes : r if jsonencode(r.object_matchers) == jsonencode([["alertname", "=", "Task run over its ceiling — critical"]]) && r.receiver == "slack-costs" && r.repeat_interval == "168h"]) == 1
    error_message = "an over-ceiling run is reported once, to the pipeline channel, not every 4 hours while its bill stands"
  }
}

run "the_overview_follows_the_house_style" {
  command = plan

  module {
    source = "./grafana"
  }

  variables {
    cost = { providers = ["aws", "databricks"] }
  }

  assert {
    condition     = jsondecode(output.files["grafana/dashboards/Cost/overview.json"]).uid == "cost-overview" && jsondecode(output.files["grafana/dashboards/Cost/overview.json"]).title == "Cost · Overview" && jsondecode(output.files["grafana/dashboards/Cost/overview.json"]).editable == false && jsondecode(output.files["grafana/dashboards/Cost/overview.json"]).refresh == "30s" && jsonencode(jsondecode(output.files["grafana/dashboards/Cost/overview.json"]).time) == jsonencode({ from = "now-90d", to = "now" })
    error_message = "the overview is read-only, over the last 90 days, refreshed every 30 seconds"
  }

  assert {
    condition     = jsonencode([for v in jsondecode(output.files["grafana/dashboards/Cost/overview.json"]).templating.list : v.name]) == jsonencode(["provider", "account", "project", "environment"]) && alltrue([for v in jsondecode(output.files["grafana/dashboards/Cost/overview.json"]).templating.list : v.datasource.uid == "cost" && v.multi && v.includeAll])
    error_message = "four multi-value filters, each from the cost database"
  }

  assert {
    condition     = length(distinct([for p in jsondecode(output.files["grafana/dashboards/Cost/overview.json"]).panels : p.id])) == length(jsondecode(output.files["grafana/dashboards/Cost/overview.json"]).panels) && alltrue([for i, p in jsondecode(output.files["grafana/dashboards/Cost/overview.json"]).panels : p.type != "row" || try(jsondecode(output.files["grafana/dashboards/Cost/overview.json"]).panels[i + 1].type, "") == "text"]) && alltrue([for p in jsondecode(output.files["grafana/dashboards/Cost/overview.json"]).panels : contains(["row", "text"], p.type) || trimspace(try(p.description, "")) != ""])
    error_message = "unique ids, every row opens with text, every panel has a description"
  }

  assert {
    condition     = length([for p in jsondecode(output.files["grafana/dashboards/Cost/overview.json"]).panels : p if contains([32, 42, 53], p.id)]) == 3
    error_message = "the panels the cost rules link are there"
  }
}

run "every_cost_panel_reads_the_cost_database" {
  command = plan

  module {
    source = "./grafana"
  }

  variables {
    cost = { providers = ["aws", "databricks"] }
  }

  assert {
    condition     = alltrue(flatten([for path, body in output.files : [for p in jsondecode(body).panels : [for t in try(p.targets, []) : t.datasource.uid == "cost" && strcontains(t.rawSql, "cost.")]] if startswith(path, "grafana/dashboards/Cost/")]))
    error_message = "every query of every cost dashboard reads the cost database's own objects"
  }
}

run "every_cost_filter_guards_all" {
  command = plan

  module {
    source = "./grafana"
  }

  variables {
    cost = { providers = ["aws", "databricks"] }
  }

  assert {
    condition     = alltrue(flatten([for path, body in output.files : [for v in jsondecode(body).templating.list : !v.multi || try(v.allValue, "") == "'__all'"] if startswith(path, "grafana/dashboards/Cost/")]))
    error_message = "every multi-value cost filter says All as '__all', so an empty one can't become IN ()"
  }

  assert {
    condition = alltrue(flatten([for path, body in output.files : [
      for p in jsondecode(body).panels : [
        for t in try(p.targets, []) : [
          for v in jsondecode(body).templating.list : !v.multi || !strcontains(t.rawSql, format("$%s", v.name)) || strcontains(t.rawSql, format("'__all' IN ($%s)", v.name))
        ]
      ]
    ] if startswith(path, "grafana/dashboards/Cost/")]))
    error_message = "every query that filters on a multi-value variable lets '__all' through"
  }
}

run "the_overview_needs_cost" {
  command = plan

  module {
    source = "./grafana"
  }

  assert {
    condition     = !contains(keys(output.files), "grafana/dashboards/Cost/overview.json")
    error_message = "a host-only node has no cost dashboards"
  }
}

run "the_budget_and_anomaly_panels_state_their_numbers" {
  command = plan

  module {
    source = "./grafana"
  }

  variables {
    cost       = { providers = ["aws", "databricks"] }
    thresholds = merge(var.thresholds, { anomaly_ratio = { warning = 3, critical = 6 } })
  }

  assert {
    condition     = strcontains(one([for p in jsondecode(output.files["grafana/dashboards/Cost/overview.json"]).panels : p.description if p.id == 32]), "100")
    error_message = "the budgets table says when a budget alerts"
  }

  assert {
    condition     = strcontains(one([for p in jsondecode(output.files["grafana/dashboards/Cost/overview.json"]).panels : p.description if p.id == 42]), "3") && strcontains(one([for p in jsondecode(output.files["grafana/dashboards/Cost/overview.json"]).panels : p.description if p.id == 42]), "6")
    error_message = "the movers table states the anomaly thresholds"
  }
}

run "cost_rules_run_sql_on_the_cost_database" {
  command = plan

  module {
    source = "./grafana"
  }

  variables {
    cost = { providers = ["aws", "databricks"] }
  }

  assert {
    condition     = length(flatten([for gr in jsondecode(output.files["grafana/provisioning/alerting/rules-cost.json"]).groups : gr.rules])) == 5 && alltrue([for r in flatten([for gr in jsondecode(output.files["grafana/provisioning/alerting/rules-cost.json"]).groups : gr.rules]) : one([for d in r.data : d if d.refId == "A"]).datasourceUid == "cost" && one([for d in r.data : d if d.refId == "A"]).model.format == "table" && strcontains(one([for d in r.data : d if d.refId == "A"]).model.rawSql, "FROM cost.")])
    error_message = "all five cost rules are SQL on the cost database, in table form"
  }

  assert {
    condition     = strcontains(one([for d in one([for r in flatten([for gr in jsondecode(output.files["grafana/provisioning/alerting/rules-cost.json"]).groups : gr.rules]) : r if r.uid == "cost-anomaly-warning"]).data : d if d.refId == "A"]).model.rawSql, "excess > 2")
    error_message = "the anomaly rule carries the default floor"
  }

  assert {
    condition     = alltrue([for r in flatten([for gr in jsondecode(output.files["grafana/provisioning/alerting/rules-cost.json"]).groups : gr.rules]) : r.labels.area == "cost" && endswith(r.for, "m") && tonumber(trimsuffix(r.for, "m")) >= 2]) && jsonencode([for gr in jsondecode(output.files["grafana/provisioning/alerting/rules-cost.json"]).groups : { name = gr.name, folder = gr.folder, interval = gr.interval }]) == jsonencode([{ name = "cost", folder = "Cost", interval = "5m" }])
    error_message = "area cost, at least 2 minutes, in the Cost folder every 5 minutes"
  }
}

run "the_anomaly_floor_reaches_the_rule" {
  command = plan

  module {
    source = "./grafana"
  }

  variables {
    cost = { providers = ["aws"], anomaly_floor_usd = 5 }
  }

  assert {
    condition     = strcontains(one([for d in one([for r in flatten([for gr in jsondecode(output.files["grafana/provisioning/alerting/rules-cost.json"]).groups : gr.rules]) : r if r.uid == "cost-anomaly-critical"]).data : d if d.refId == "A"]).model.rawSql, "excess > 5")
    error_message = "the anomaly floor is the caller's"
  }
}

run "cost_rules_link_the_overview" {
  command = plan

  module {
    source = "./grafana"
  }

  variables {
    cost = { providers = ["aws", "databricks"] }
  }

  assert {
    condition     = alltrue([for r in flatten([for gr in jsondecode(output.files["grafana/provisioning/alerting/rules-cost.json"]).groups : gr.rules]) : r.annotations.__dashboardUid__ == "cost-overview" && length([for p in jsondecode(output.files["grafana/dashboards/Cost/overview.json"]).panels : p if tostring(p.id) == r.annotations.__panelId__]) == 1])
    error_message = "each cost rule links its Overview panel"
  }
}

run "the_cost_rules_need_cost" {
  command = plan

  module {
    source = "./grafana"
  }

  assert {
    condition     = length(flatten([for gr in jsondecode(output.files["grafana/provisioning/alerting/rules-cost.json"]).groups : gr.rules])) == 0 && length([for d in jsondecode(output.files["grafana/provisioning/alerting/rules-cost.json"]).deleteRules : d.uid]) == 5
    error_message = "without cost, every cost rule is deleted"
  }
}

run "cost_thresholds_reach_the_rules" {
  command = plan

  module {
    source = "./grafana"
  }

  variables {
    cost       = { providers = ["aws", "databricks"] }
    thresholds = merge(var.thresholds, { anomaly_ratio = { warning = 3, critical = 6 }, untagged_daily_usd = { warning = 1.5 } })
  }

  assert {
    condition     = one([for d in one([for r in flatten([for gr in jsondecode(output.files["grafana/provisioning/alerting/rules-cost.json"]).groups : gr.rules]) : r if r.uid == "cost-anomaly-warning"]).data : d.model.conditions[0].evaluator.params[0] if d.refId == "C"]) == 3 && one([for d in one([for r in flatten([for gr in jsondecode(output.files["grafana/provisioning/alerting/rules-cost.json"]).groups : gr.rules]) : r if r.uid == "cost-anomaly-critical"]).data : d.model.conditions[0].evaluator.params[0] if d.refId == "C"]) == 6 && one([for d in one([for r in flatten([for gr in jsondecode(output.files["grafana/provisioning/alerting/rules-cost.json"]).groups : gr.rules]) : r if r.uid == "cost-untagged-new-warning"]).data : d.model.conditions[0].evaluator.params[0] if d.refId == "C"]) == 1.5 && one([for d in one([for r in flatten([for gr in jsondecode(output.files["grafana/provisioning/alerting/rules-cost.json"]).groups : gr.rules]) : r if r.uid == "cost-budget-spent-critical"]).data : d.model.conditions[0].evaluator.params[0] if d.refId == "C"]) == 100
    error_message = "the cost thresholds reach the rules; budgets alert past 100 %"
  }
}

run "cost_alerts_post_once_then_weekly" {
  command = plan

  module {
    source = "./grafana"
  }

  variables {
    cost  = { providers = ["aws"] }
    slack = { channels = { platform = "/acme/monitoring/slack/platform", costs = "/acme/monitoring/slack/costs" }, routes = { host = "platform", cost = "costs" } }
  }

  assert {
    condition     = jsonencode([for r in one(jsondecode(output.files["grafana/provisioning/alerting/policies.json"]).policies).routes : [r.receiver, lookup(r, "repeat_interval", "")] if jsonencode(r.object_matchers) == jsonencode([["area", "=", "cost"]])]) == jsonencode([["slack-costs", "168h"]])
    error_message = "a breached budget stays breached, a judged day stays judged: the cost alerts post once, then weekly, to the cost channel"
  }
}

run "cost_alerts_fall_back_to_the_host_channel" {
  command = plan

  module {
    source = "./grafana"
  }

  variables {
    cost  = { providers = ["aws"] }
    slack = { channels = { platform = "/acme/monitoring/slack/platform" }, routes = { host = "platform" } }
  }

  assert {
    condition     = length([for r in one(jsondecode(output.files["grafana/provisioning/alerting/policies.json"]).policies).routes : r if jsonencode(r.object_matchers) == jsonencode([["area", "=", "cost"]]) && r.receiver == "slack-platform" && r.repeat_interval == "168h"]) == 1
    error_message = "with no cost channel, the cost alerts go to the host channel, still weekly"
  }
}

run "cost_rules_judge_each_recent_day_and_each_new_pair" {
  command = plan

  module {
    source = "./grafana"
  }

  variables {
    cost = { providers = ["aws"] }
  }

  assert {
    condition     = strcontains(one([for d in one([for r in flatten([for gr in jsondecode(output.files["grafana/provisioning/alerting/rules-cost.json"]).groups : gr.rules]) : r if r.uid == "cost-anomaly-warning"]).data : d if d.refId == "A"]).model.rawSql, "day::text AS day") && strcontains(one([for d in one([for r in flatten([for gr in jsondecode(output.files["grafana/provisioning/alerting/rules-cost.json"]).groups : gr.rules]) : r if r.uid == "cost-untagged-new-warning"]).data : d if d.refId == "A"]).model.rawSql, "WHERE is_new")
    error_message = "each judged day is its own alert, and an untagged pair is new on its first or second day"
  }
}
