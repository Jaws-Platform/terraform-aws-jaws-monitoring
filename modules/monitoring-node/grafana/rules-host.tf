# The host alert rules: warning and critical pairs, each mirroring a panel of
# the host dashboard (the same query, the same numbers as its dashed lines),
# with labels area = host and severity for routing.
#
#   for          never under 2m: a Prometheus or Grafana restart during a config
#                change must not post (every rule alerts on a query error);
#                rule-eval-failures waits 12m, longer than its 10-minute window,
#                since one failed tick keeps that window above zero for 10m
#   noDataState  OK, except CloudWatch's, where no data means a wrong instance
#   deleteRules  every catalogue uid not rendered (a feature switched off, a
#                severity with no threshold): Grafana deletes a provisioned rule
#                only when told to
#
# Counts that fire on a whole number n use n - 0.5 (offset 0.5): increase()
# extrapolates, so one event can read 0.97. Their panel lines sit at n.

locals {
  host_rule_specs = [
    { key = "cpu", title = "CPU used", source = "prometheus", query = local.q.cpu, op = "gt", warning = local.t.cpu_percent.warning, critical = local.t.cpu_percent.critical, offset = 0, for = "2m", panel = 12, needed = true, summary = "CPU averaged above %v %% over 10 minutes." },
    # Its severities stay in the catalogue on a type without credits (the
    # values are then 0 and never rendered), so switching to one deletes them.
    { key = "cpu-credits", title = "CPU credit balance", source = "cloudwatch", query = null, op = "lt", warning = local.t.cpu_credits_percent.warning * coalesce(local.credits_max, 0) / 100, critical = local.t.cpu_credits_percent.critical * coalesce(local.credits_max, 0) / 100, offset = 0, for = "15m", panel = 13, needed = local.burstable, summary = "The CPU credit balance is below %v credits; at zero the instance is held to its baseline CPU." },
    { key = "memory", title = "Memory used", source = "prometheus", query = local.q.memory, op = "gt", warning = local.t.memory_percent.warning, critical = local.t.memory_percent.critical, offset = 0, for = "2m", panel = 22, needed = true, summary = "Memory in use averaged above %v %% over 5 minutes." },
    { key = "swap", title = "Swap used", source = "prometheus", query = local.q.swap, op = "gt", warning = local.t.swap_percent.warning, critical = local.t.swap_percent.critical, offset = 0, for = "2m", panel = 23, needed = true, summary = "Swap in use averaged above %v %% over 15 minutes." },
    { key = "oom-kill", title = "OOM kill", source = "prometheus", query = local.q.oom_kills, op = "gt", warning = null, critical = 0.5, offset = 0.5, for = "2m", panel = 24, needed = true, summary = "The kernel killed a process for lack of memory in the last 10 minutes." },
    { key = "disk", title = "Disk used", source = "prometheus", query = local.q.disk, op = "gt", warning = local.t.disk_percent.warning, critical = local.t.disk_percent.critical, offset = 0, for = "5m", panel = 32, needed = true, summary = "A volume is more than %v %% full." },
    { key = "disk-full", title = "Disk full forecast", source = "prometheus", query = local.q.disk_full_days, op = "lt", warning = local.t.disk_full_days.warning, critical = local.t.disk_full_days.critical, offset = 0, for = "30m", panel = 33, needed = true, summary = "At its last 24 hours' growth, a volume is full within %v days." },
    { key = "inodes", title = "Inodes used", source = "prometheus", query = local.q.inodes, op = "gt", warning = local.t.inodes_percent.warning, critical = local.t.inodes_percent.critical, offset = 0, for = "5m", panel = 34, needed = true, summary = "A volume has used more than %v %% of its inodes." },
    { key = "prometheus-history", title = "Prometheus cap cutting history", source = "prometheus", query = "${local.q.prometheus_history_days} and on() (${local.q.prometheus_size} > ${local.t.prometheus_size_percent.warning})", op = "lt", warning = local.t.prometheus_history_days.warning, critical = null, offset = 0, for = "15m", panel = 38, needed = true, summary = "Prometheus is at its size cap and keeps fewer than %v days of metrics. Raise prometheus_retention.size_gb (and data_volume_gb) to keep more." },
    { key = "target-down", title = "Scrape target down", source = "prometheus", query = local.q.up, op = "lt", warning = null, critical = 0.5, offset = 0.5, for = "2m", panel = 42, needed = true, summary = "A scrape target is down: Prometheus can't reach it." },
    { key = "container-restarts", title = "Container restarts", source = "prometheus", query = local.q.restarts, op = "gt", warning = local.t.container_restarts.warning - 0.5, critical = local.t.container_restarts.critical - 0.5, offset = 0.5, for = "2m", panel = 43, needed = true, summary = "Docker restarted a container %v or more times in 15 minutes." },
    { key = "tls-expiry", title = "TLS certificate expiry", source = "prometheus", query = local.q.tls_days, op = "lt", warning = local.t.tls_days.warning, critical = local.t.tls_days.critical, offset = 0, for = "2m", panel = 45, needed = local.served, summary = "The public certificate expires within %v days; Caddy should have renewed it by now." },
    { key = "rule-eval-failures", title = "Grafana rule-evaluation failures", source = "prometheus", query = local.q.eval_failures, op = "gt", warning = 0.5, critical = null, offset = 0.5, for = "12m", panel = 47, needed = true, summary = "Grafana alert rules failed to evaluate in the last 10 minutes: a broken query, or a data source it can't reach." },
    { key = "os-release", title = "Newer AL2023 release available", source = "prometheus", query = local.q.os_update_days, op = "gt", warning = local.t.os_release_update_days.warning, critical = null, offset = 0, for = "2m", panel = 52, needed = true, summary = "A newer Amazon Linux 2023 release has been out for more than %v days: time for an AMI bump." },
  ]
}
