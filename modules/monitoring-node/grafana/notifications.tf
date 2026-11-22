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

  # With a schedule, the first 15 minutes after each scheduled start are muted
  # (6.10): targets come up and cost-sync catches up. Every area gets its own
  # route then (its channel, or host's), since the root can't be muted.
  muted      = local.slack_on && var.schedule != null
  mute_name  = "after-scheduled-start"
  mute       = { for k, v in { mute_time_intervals = [local.mute_name] } : k => v if local.muted }
  weekday    = { mon = "monday", tue = "tuesday", wed = "wednesday", thu = "thursday", fri = "friday", sat = "saturday", sun = "sunday" }
  area_names = local.muted ? distinct(concat(keys(local.slack_routes), ["host", "pipeline"])) : keys(local.slack_routes)

  mute_file = "grafana/provisioning/alerting/mute-timings.json"
  mute_files = merge(
    { for path, doc in { (local.mute_file) = {
      apiVersion = 1
      muteTimes = [{
        orgId = 1
        name  = local.mute_name
        time_intervals = [{
          times    = [{ start_time = try(var.schedule.on, ""), end_time = format("%s:15", substr(try(var.schedule.on, "00"), 0, 2)) }]
          weekdays = [for d in ["mon", "tue", "wed", "thu", "fri", "sat", "sun"] : local.weekday[d] if contains(try(var.schedule.days, []), d)]
          location = try(var.schedule.timezone, "")
        }]
      }]
    } } : path => doc if local.muted },
    { for path, doc in { (local.mute_file) = { apiVersion = 1, deleteMuteTimes = [{ orgId = 1, name = local.mute_name }] } } : path => doc if !local.muted },
  )

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
        routes = concat(
          # A due AMI bump can stay due for days: remind once a day.
          [merge({
            receiver        = "slack-${lookup(local.slack_routes, "host", "")}"
            object_matchers = [["alertname", "=", local.rule_common["host-os-release-warning"].title]]
            repeat_interval = "24h"
          }, local.mute)],
          # A run over its ceiling stays over (its bill only grows): say it once.
          [for r in [merge({
            receiver        = "slack-${lookup(local.slack_routes, "pipeline", lookup(local.slack_routes, "host", ""))}"
            object_matchers = [["alertname", "=", "${one([for s in local.pipeline_rule_specs : s.title if s.key == "task-run-over-ceiling"])} — critical"]]
            repeat_interval = "168h"
          }, local.mute)] : r if local.cost_on],
          # A breached budget stays breached all month, and a judged day or a new
          # charge stays what it was: say it once, then weekly while it lasts.
          [for r in [merge({
            receiver        = "slack-${lookup(local.slack_routes, "cost", lookup(local.slack_routes, "host", ""))}"
            object_matchers = [["area", "=", "cost"]]
            repeat_interval = "168h"
          }, local.mute)] : r if local.cost_on],
          [
            for area in sort(local.area_names) : merge({
              receiver        = "slack-${lookup(local.slack_routes, area, lookup(local.slack_routes, "host", ""))}"
              object_matchers = [["area", "=", area]]
            }, local.mute) if !(area == "cost" && local.cost_on)
          ],
        )
      }]
    }
  }

  no_slack_files = {
    "grafana/provisioning/alerting/policies.json" = { apiVersion = 1, resetPolicies = [1] }
  }

  notification_files = merge(
    local.mute_files,
    { for path, doc in local.slack_files : path => doc if local.slack_on },
    { for path, doc in local.no_slack_files : path => doc if !local.slack_on },
  )
}
