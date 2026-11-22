# Slack: one contact point per channel, one notification policy per area, and
# the one message template (ported from prog-strength's ps-slack). Without
# Slack, the stored policy tree is reset, so a removed Slack leaves nothing
# pointing at its webhooks; alerts then show in Grafana only.
#
# A channel's webhook URL never enters the bundle: the contact point names the
# variable ($SLACK_WEBHOOK_<CHANNEL>), Grafana expands it from its environment,
# and the reconciler puts it there from the channel's SSM parameter.

locals {
  slack_on       = var.slack != null
  slack_channels = local.slack_on ? var.slack.channels : {}
  slack_routes   = local.slack_on ? var.slack.routes : {}

  webhook_env = { for c in keys(local.slack_channels) : c => "SLACK_WEBHOOK_${upper(replace(c, "-", "_"))}" }

  # No $ anywhere: Grafana doesn't expand template content, but a $ here would
  # still be a mistake waiting for the day it does. Go templates use dots.
  slack_template = <<-EOT
    {{ define "monitoring.title" -}}
    {{ if eq .Status "firing" }}🚨 [FIRING]{{ else }}✅ [RESOLVED]{{ end }} {{ .CommonLabels.alertname }}
    {{- end }}

    {{ define "monitoring.text" -}}
    {{ range .Alerts }}
    {{ if eq .Status "firing" }}:red_circle:{{ else }}:large_green_circle:{{ end }} *{{ .Labels.alertname }}*{{ if .Labels.severity }} — severity: *{{ .Labels.severity }}*{{ end }}
    {{ if .Annotations.summary }}{{ .Annotations.summary }}{{ end }}
    {{ range .Labels.SortedPairs }}{{ if and (ne .Name "alertname") (ne .Name "grafana_folder") (ne .Name "severity") }}• {{ .Name }}: `{{ .Value }}`
    {{ end }}{{ end -}}
    Observed: {{ .ValueString }}
    {{ if .PanelURL }}<{{ .PanelURL }}|View panel>{{ else if .DashboardURL }}<{{ .DashboardURL }}|View dashboard>{{ end }}
    {{ end }}
    {{- end }}
  EOT

  slack_files = {
    "grafana/provisioning/alerting/templates.json" = {
      apiVersion = 1
      templates  = [{ orgId = 1, name = "monitoring-slack", template = local.slack_template }]
    }
    "grafana/provisioning/alerting/contact-points.json" = {
      apiVersion = 1
      contactPoints = [
        for c in sort(keys(local.slack_channels)) : {
          orgId = 1
          name  = "slack-${c}"
          receivers = [{
            uid                   = "slack-${c}"
            type                  = "slack"
            disableResolveMessage = false
            settings = {
              url   = format("$%s", local.webhook_env[c])
              title = "{{ template \"monitoring.title\" . }}"
              text  = "{{ template \"monitoring.text\" . }}"
            }
          }]
        }
      ]
    }
    "grafana/provisioning/alerting/policies.json" = {
      apiVersion = 1
      policies = [{
        orgId           = 1
        receiver        = "slack-${lookup(local.slack_routes, "host", "")}"
        group_by        = ["grafana_folder", "alertname"]
        group_wait      = "30s"
        group_interval  = "5m"
        repeat_interval = "4h"
        routes = [
          for area in sort(keys(local.slack_routes)) : {
            receiver        = "slack-${local.slack_routes[area]}"
            object_matchers = [["area", "=", area]]
          }
        ]
      }]
    }
  }

  no_slack_files = {
    "grafana/provisioning/alerting/policies.json" = { apiVersion = 1, resetPolicies = [1] }
  }

  notification_files = merge(
    { for path, doc in local.slack_files : path => doc if local.slack_on },
    { for path, doc in local.no_slack_files : path => doc if !local.slack_on },
  )
}
