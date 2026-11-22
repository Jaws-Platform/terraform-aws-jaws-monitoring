# The Grafana config module: every file under grafana/ in the bundle. It has no
# providers, so these runs plan it directly. The rules validator is a
# precondition on its files output: a rule Grafana would reject at boot (and
# take all of provisioning down with it) fails the plan instead.

variables {
  region            = "us-east-1"
  extra_dashboards  = {}
  extra_alert_rules = {}
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
