# One table of PromQL for the panels and the rules, so a panel always plots
# exactly what its rule evaluates. Windows are fixed (no Grafana macros), so
# every query is plain PromQL that promtool can check.

locals {
  # The node's two volumes: / (the OS and images) and /data (everything kept).
  volumes = "mountpoint=~\"/|/data\""

  q = {
    cpu             = "100 * (1 - avg(rate(node_cpu_seconds_total{mode=\"idle\"}[10m])))"
    memory          = "avg_over_time((100 * (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes))[5m:1m])"
    swap            = "avg_over_time((100 * (1 - node_memory_SwapFree_bytes / clamp_min(node_memory_SwapTotal_bytes, 1)))[15m:1m])"
    oom_kills       = "increase(node_vmstat_oom_kill[10m])"
    disk            = "100 * (1 - node_filesystem_avail_bytes{${local.volumes}} / node_filesystem_size_bytes{${local.volumes}})"
    disk_full_days  = "node_filesystem_avail_bytes{${local.volumes}} / -(deriv(node_filesystem_avail_bytes{${local.volumes}}[24h]) < 0) / 86400"
    inodes          = "100 * (1 - node_filesystem_files_free{${local.volumes}} / node_filesystem_files{${local.volumes}})"
    prometheus_size = "100 * (prometheus_tsdb_storage_blocks_bytes + prometheus_tsdb_wal_storage_size_bytes + prometheus_tsdb_head_chunks_storage_size_bytes) / prometheus_tsdb_retention_limit_bytes"
    # How far back Prometheus's oldest sample is, in days.
    prometheus_history_days = "(time() - prometheus_tsdb_lowest_timestamp_seconds) / 86400"
    up                      = "up"
    # Docker's own restarts of a container: a container a reconcile recreates
    # is a new series, so a config change doesn't count.
    restarts       = "changes(container_start_time_seconds{name=~\".+\"}[15m])"
    tls_days       = "(probe_ssl_earliest_cert_expiry - time()) / 86400"
    eval_failures  = "sum(increase(grafana_alerting_rule_evaluation_failures_total[10m]))"
    os_update_days = "(time() - monitoring_os_release_update_since_seconds) / 86400 and monitoring_os_release_update_available == 1"
  }

  # CPU credits: burstable types, and the balance each size can hold (the
  # earn rate times 24). T9g is assumed to match T4g until plan 09 checks it.
  burstable_families  = ["t3", "t3a", "t4g", "t9g"]
  credits_max_by_size = { nano = 144, micro = 288, small = 576, medium = 576, large = 864, xlarge = 2304, "2xlarge" = 4608 }
  instance_family     = split(".", var.instance_type)[0]
  instance_size       = try(split(".", var.instance_type)[1], "")
  credits_max         = contains(local.burstable_families, local.instance_family) ? lookup(local.credits_max_by_size, local.instance_size, null) : null
  burstable           = local.credits_max != null
  served              = var.domain != null

  # The CloudWatch query for the credit balance (panel and rule).
  credits_query = {
    datasource       = { type = "cloudwatch", uid = "cloudwatch" }
    queryMode        = "Metrics"
    namespace        = "AWS/EC2"
    metricName       = "CPUCreditBalance"
    dimensions       = { InstanceId = [var.instance_id] }
    statistic        = "Minimum"
    period           = "300"
    region           = "default"
    matchExact       = true
    metricQueryType  = 0
    metricEditorMode = 0
    id               = ""
    expression       = ""
    label            = ""
  }

  # Thresholds as the dashboard draws them: key => the warning and critical
  # lines (null: none), their unit and their legend words. Counts that fire on
  # a whole number are drawn at that number.
  t = var.thresholds
  lines = {
    cpu        = { warning = local.t.cpu_percent.warning, critical = local.t.cpu_percent.critical, unit = "%", worse = "above", words = ["warning", "critical"] }
    credits    = { warning = local.burstable ? local.t.cpu_credits_percent.warning * local.credits_max / 100 : null, critical = local.burstable ? local.t.cpu_credits_percent.critical * local.credits_max / 100 : null, unit = " credits", worse = "below", words = ["warning", "critical"] }
    memory     = { warning = local.t.memory_percent.warning, critical = local.t.memory_percent.critical, unit = "%", worse = "above", words = ["warning", "critical"] }
    swap       = { warning = local.t.swap_percent.warning, critical = local.t.swap_percent.critical, unit = "%", worse = "above", words = ["warning", "critical"] }
    oom        = { warning = null, critical = 1, unit = "", worse = "at", words = ["warning", "critical"] }
    disk       = { warning = local.t.disk_percent.warning, critical = local.t.disk_percent.critical, unit = "%", worse = "above", words = ["warning", "critical"] }
    disk_full  = { warning = local.t.disk_full_days.warning, critical = local.t.disk_full_days.critical, unit = " days", worse = "below", words = ["warning", "critical"] }
    inodes     = { warning = local.t.inodes_percent.warning, critical = local.t.inodes_percent.critical, unit = "%", worse = "above", words = ["warning", "critical"] }
    prom_size  = { warning = local.t.prometheus_size_percent.warning, critical = null, unit = "%", worse = "above", words = ["at the cap", "critical"] }
    history    = { warning = local.t.prometheus_history_days.warning, critical = null, unit = " days", worse = "below", words = ["warning", "critical"] }
    up         = { warning = null, critical = 1, unit = "", worse = "below", words = ["warning", "critical"] }
    restarts   = { warning = local.t.container_restarts.warning, critical = local.t.container_restarts.critical, unit = "", worse = "at", words = ["warning", "critical"] }
    tls        = { warning = local.t.tls_days.warning, critical = local.t.tls_days.critical, unit = " days", worse = "below", words = ["warning", "critical"] }
    eval       = { warning = 1, critical = null, unit = "", worse = "at", words = ["warning", "critical"] }
    os_release = { warning = local.t.os_release_update_days.warning, critical = null, unit = " days", worse = "above", words = ["warning", "critical"] }
  }
}
