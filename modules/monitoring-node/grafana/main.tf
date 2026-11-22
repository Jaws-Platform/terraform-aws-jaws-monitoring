# Every file under grafana/ in the config bundle, keyed by its path in the
# bundle:
#
#   grafana/provisioning/datasources/datasources.yaml
#   grafana/provisioning/dashboards/dashboards.yaml   the dashboard folder
#   grafana/dashboards/<Folder>/<name>.json           dashboards (folder = directory)
#   grafana/provisioning/alerting/*.json              rules, templates, contact
#                                                     points and policies
#
# Alerting files are JSON (Grafana reads YAML or JSON there), so the smoke test
# can read them with Python's stdlib.

locals {
  datasources = yamlencode({
    apiVersion = 1
    # prune is meant to drop a data source removed from this file, but Grafana
    # 13.3 keeps it (the smoke test's phase 2 shows it), so the Cost data
    # source is deleted by name whenever cost is off.
    prune             = true
    deleteDatasources = [for d in [{ name = "Cost", orgId = 1 }] : d if var.cost == null]
    datasources = concat([
      {
        name      = "Prometheus"
        uid       = "prometheus"
        type      = "prometheus"
        access    = "proxy"
        url       = "http://prometheus:9090"
        isDefault = true
        jsonData  = { timeInterval = "15s" }
      },
      {
        name     = "CloudWatch"
        uid      = "cloudwatch"
        type     = "cloudwatch"
        access   = "proxy"
        jsonData = { authType = "default", defaultRegion = var.region }
      },
      ], [
      # The cost database cost-sync keeps, read as its read-only user. The
      # password is expanded from Grafana's environment.
      for d in [{
        name           = "Cost"
        uid            = "cost"
        type           = "grafana-postgresql-datasource"
        access         = "proxy"
        url            = "postgres:5432"
        user           = "cost_reader"
        secureJsonData = { password = "$COST_READER_PASSWORD" }
        jsonData       = { database = "cost", sslmode = "disable", postgresVersion = 1700 }
      }] : d if var.cost != null
    ])
  })

  dashboard_providers = yamlencode({
    apiVersion = 1
    providers = [{
      name  = "monitoring"
      orgId = 1
      type  = "file"
      # A dashboard whose file is gone leaves Grafana too (the smoke test's
      # phase 2 shows it would stay with this on).
      disableDeletion       = false
      allowUiUpdates        = false
      updateIntervalSeconds = 60
      options               = { path = "/var/lib/grafana/dashboards", foldersFromFilesStructure = true }
    }]
  })

  # Dashboards: path under grafana/dashboards/ => JSON. The directory is the
  # Grafana folder, the same folder the host rules go in.
  module_dashboards = merge(
    { "Monitoring/host.json" = jsonencode(local.host_dashboard) },
    { for path, d in { "Cost/overview.json" = local.cost_overview } : path => jsonencode(d) if local.cost_on },
  )
  dashboards = merge(local.module_dashboards, var.extra_dashboards)

  # Alerting provisioning files the module renders: path => document (an
  # object, encoded below).
  module_alerting = merge(
    {
      "grafana/provisioning/alerting/rules-host.json"     = local.rules_files.host
      "grafana/provisioning/alerting/rules-pipeline.json" = local.rules_files.pipeline
    },
    local.notification_files,
  )

  extra_rules_path = { for name, _ in var.extra_alert_rules : name => "grafana/provisioning/alerting/rules-extra-${name}.json" }

  files = merge(
    {
      "grafana/provisioning/datasources/datasources.yaml" = local.datasources
      "grafana/provisioning/dashboards/dashboards.yaml"   = local.dashboard_providers
      # The node mounts this tree over the image's own, so every folder Grafana
      # reads must exist; an empty plugins/ spares an error at every start.
      "grafana/provisioning/plugins/plugins.yaml" = yamlencode({ apiVersion = 1, apps = [] })
    },
    { for path, json in local.dashboards : "grafana/dashboards/${path}" => json },
    { for path, doc in local.module_alerting : path => jsonencode(doc) },
    # A caller's YAML, provisioned as JSON. If it doesn't decode, the validator
    # fails the plan, so the raw text never reaches Grafana.
    { for name, yaml in var.extra_alert_rules : local.extra_rules_path[name] => try(jsonencode(yamldecode(yaml)), yaml) },
  )
}
