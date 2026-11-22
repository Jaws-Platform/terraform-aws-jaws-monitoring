# The monitoring node: one IMDSv2 instance with a separate data volume, no
# ingress unless it serves HTTPS, a role that reads only its bundle and secrets,
# and a config bundle named by an SSM parameter. Mock provider: nothing is called.

mock_provider "aws" {
  override_during = plan

  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
    }
  }

  mock_data "aws_region" {
    defaults = {
      region = "us-east-1"
    }
  }

  mock_data "aws_subnet" {
    defaults = {
      availability_zone = "us-east-1a"
    }
  }

  mock_data "aws_ami" {
    defaults = {
      id = "ami-0123456789abcdef0"
    }
  }

  mock_resource "aws_instance" {
    defaults = {
      id        = "i-0123456789abcdef0"
      public_ip = "198.51.100.7"
    }
  }

  mock_resource "aws_ebs_volume" {
    defaults = {
      id = "vol-0123456789abcdef0"
    }
  }
}

variables {
  name      = "acme-monitoring"
  vpc_id    = "vpc-0123"
  subnet_id = "subnet-0123"
  ami_name  = "al2023-ami-2023.12.20261026.1-kernel-6.18-arm64"
  grafana_admin = {
    user_parameter     = "/acme/monitoring/grafana-admin-user"
    password_parameter = "/acme/monitoring/grafana-admin-password"
  }
}

run "the_instance_is_imdsv2_standard_credits_encrypted_and_public" {
  command = plan

  assert {
    condition     = aws_instance.this.ami == "ami-0123456789abcdef0" && aws_instance.this.instance_type == "t9g.medium"
    error_message = "the AMI comes from ami_name, and the type defaults to t9g.medium"
  }

  assert {
    condition     = aws_instance.this.metadata_options[0].http_tokens == "required" && aws_instance.this.metadata_options[0].http_put_response_hop_limit == 2
    error_message = "IMDSv2 only, with a hop limit of 2 so containers on the Docker bridge reach instance metadata"
  }

  assert {
    condition     = aws_instance.this.credit_specification[0].cpu_credits == "standard"
    error_message = "standard CPU credits: a burst never bills extra"
  }

  assert {
    condition     = aws_instance.this.root_block_device[0].volume_type == "gp3" && aws_instance.this.root_block_device[0].encrypted && aws_instance.this.root_block_device[0].volume_size == 12
    error_message = "a 12 GB encrypted gp3 root volume"
  }

  assert {
    condition     = aws_instance.this.associate_public_ip_address && aws_instance.this.user_data_replace_on_change
    error_message = "a public IPv4 address, and a new instance when the bootstrap changes"
  }

  assert {
    condition     = aws_instance.this.tags == tomap({ Name = "acme-monitoring", Component = "monitoring" })
    error_message = "the module sets Name and Component only"
  }

  assert {
    condition     = data.aws_ami.this.owners == tolist(["amazon"]) && contains([for f in data.aws_ami.this.filter : one(f.values) if f.name == "name"], "al2023-ami-2023.12.20261026.1-kernel-6.18-arm64") && contains([for f in data.aws_ami.this.filter : one(f.values) if f.name == "architecture"], "arm64")
    error_message = "the AMI is Amazon's arm64 image of exactly ami_name"
  }
}

run "the_data_volume_is_separate_and_survives_the_instance" {
  command = plan

  assert {
    condition     = aws_ebs_volume.data.size == 30 && aws_ebs_volume.data.type == "gp3" && aws_ebs_volume.data.encrypted && aws_ebs_volume.data.availability_zone == "us-east-1a"
    error_message = "a 30 GB encrypted gp3 volume in the subnet's zone"
  }

  assert {
    condition     = aws_ebs_volume.data.tags == tomap({ Name = "acme-monitoring-data", Component = "monitoring" })
    error_message = "the data volume is named, and snapshots find it by that name"
  }

  assert {
    condition     = aws_volume_attachment.data.device_name == "/dev/sdf" && aws_volume_attachment.data.stop_instance_before_detaching
    error_message = "attached as /dev/sdf, and detached only from a stopped instance"
  }
}

run "without_a_domain_nothing_is_reachable_from_outside" {
  command = plan

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.web) == 0 && length(aws_route53_record.this) == 0
    error_message = "without a domain there is no ingress and no record"
  }

  assert {
    condition     = toset(keys(aws_vpc_security_group_egress_rule.all)) == toset(["ipv4", "ipv6"])
    error_message = "egress is open, for pulls, updates and AWS APIs"
  }

  assert {
    condition     = !contains([for s in jsondecode(aws_iam_role_policy.this.policy).Statement : s.Sid], "UpdateItsDnsRecord")
    error_message = "without a domain the role touches no DNS"
  }
}

run "with_a_domain_only_web_traffic_comes_in" {
  command = plan

  variables {
    domain  = "grafana.example.com"
    zone_id = "Z123"
  }

  assert {
    condition = toset([for r in values(aws_vpc_security_group_ingress_rule.web) : "${r.from_port}/${coalesce(r.cidr_ipv4, r.cidr_ipv6)}"]) == toset([
      "443/0.0.0.0/0", "443/::/0", "80/0.0.0.0/0", "80/::/0",
    ])
    error_message = "only 443 and 80 (ACME and the redirect), from anywhere"
  }

  assert {
    condition     = aws_route53_record.this[0].type == "A" && aws_route53_record.this[0].ttl == 60 && aws_route53_record.this[0].records == toset(["198.51.100.7"]) && aws_route53_record.this[0].name == "grafana.example.com"
    error_message = "an A record with a 60 s TTL, first set to the instance's address"
  }

  assert {
    condition = one([for s in jsondecode(aws_iam_role_policy.this.policy).Statement : s if s.Sid == "UpdateItsDnsRecord"]) == {
      Sid      = "UpdateItsDnsRecord"
      Effect   = "Allow"
      Action   = "route53:ChangeResourceRecordSets"
      Resource = "arn:aws:route53:::hostedzone/Z123"
      Condition = {
        "ForAllValues:StringEquals" = {
          "route53:ChangeResourceRecordSetsNormalizedRecordNames" = ["grafana.example.com"]
          "route53:ChangeResourceRecordSetsRecordTypes"           = ["A"]
          "route53:ChangeResourceRecordSetsActions"               = ["UPSERT"]
        }
      }
    }
    error_message = "the node may only upsert its own A record"
  }
}

run "the_role_reads_its_bundle_and_secrets_and_writes_its_status" {
  command = plan

  assert {
    condition = jsondecode(aws_iam_role_policy.this.policy).Statement == [
      {
        Sid      = "ReadTheBundle"
        Effect   = "Allow"
        Action   = "s3:GetObject"
        Resource = "arn:aws:s3:::acme-monitoring-config-123456789012/bundles/*"
      },
      {
        Sid    = "ReadTheParameters"
        Effect = "Allow"
        Action = "ssm:GetParameter"
        Resource = [
          "arn:aws:ssm:us-east-1:123456789012:parameter/acme-monitoring/node/config-bundle",
          "arn:aws:ssm:us-east-1:123456789012:parameter/acme/monitoring/grafana-admin-user",
          "arn:aws:ssm:us-east-1:123456789012:parameter/acme/monitoring/grafana-admin-password",
        ]
      },
      {
        Sid    = "WriteTheStatus"
        Effect = "Allow"
        Action = "ssm:PutParameter"
        Resource = [
          "arn:aws:ssm:us-east-1:123456789012:parameter/acme-monitoring/node/status",
          "arn:aws:ssm:us-east-1:123456789012:parameter/acme-monitoring/node/running-config",
        ]
      },
      {
        Sid      = "ReadMetrics"
        Effect   = "Allow"
        Action   = ["cloudwatch:GetMetricData", "cloudwatch:ListMetrics", "cloudwatch:GetMetricStatistics"]
        Resource = "*"
      },
      {
        Sid      = "SessionManager"
        Effect   = "Allow"
        Action   = ["ssm:UpdateInstanceInformation", "ssmmessages:CreateControlChannel", "ssmmessages:CreateDataChannel", "ssmmessages:OpenControlChannel", "ssmmessages:OpenDataChannel"]
        Resource = "*"
      },
    ]
    error_message = "the node reads its bundle, its parameters and CloudWatch metrics, writes only its status, and serves Session Manager; it can read no other parameter"
  }
}

run "the_parameters_name_the_bundle" {
  command = plan

  assert {
    condition     = aws_ssm_parameter.config_bundle.name == "/acme-monitoring/node/config-bundle" && aws_ssm_parameter.config_bundle.value == aws_s3_object.bundle.key && startswith(aws_s3_object.bundle.key, "bundles/") && endswith(aws_s3_object.bundle.key, ".json")
    error_message = "the config-bundle parameter names the content-addressed bundle"
  }

  assert {
    condition     = aws_ssm_parameter.status.name == "/acme-monitoring/node/status" && aws_ssm_parameter.running_config.name == "/acme-monitoring/node/running-config"
    error_message = "the reconciler reports through status and running-config"
  }

  assert {
    condition     = aws_s3_bucket.config.bucket == "acme-monitoring-config-123456789012"
    error_message = "the config bucket is named for the node and the account"
  }
}

run "without_snapshots_there_is_no_backup_plan" {
  command = plan

  assert {
    condition     = length(aws_backup_plan.snapshots) == 0 && length(aws_backup_vault.snapshots) == 0 && length(aws_backup_selection.snapshots) == 0
    error_message = "no snapshots unless asked for"
  }
}

run "snapshots_without_a_schedule_run_at_time_utc" {
  command = plan

  variables {
    snapshots = { enabled = true }
  }

  assert {
    condition     = one(aws_backup_plan.snapshots[0].rule).schedule == "cron(0 3 ? * * *)" && one(aws_backup_plan.snapshots[0].rule).schedule_expression_timezone == "Etc/UTC"
    error_message = "one daily snapshot at 03:00 UTC"
  }
}

run "with_a_schedule_snapshots_run_after_the_stop" {
  command = plan

  variables {
    snapshots = { enabled = true }
    schedule  = { timezone = "America/Denver", days = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"], on = "08:00", off = "24:00" }
  }

  assert {
    condition     = one(aws_backup_plan.snapshots[0].rule).schedule == "cron(0 3 ? * * *)" && one(aws_backup_plan.snapshots[0].rule).schedule_expression_timezone == "America/Denver"
    error_message = "a stop at midnight snapshots at 03:00 local: an hour after it, past the hours daylight saving changes"
  }
}

run "an_evening_stop_snapshots_an_hour_later" {
  command = plan

  variables {
    snapshots = { enabled = true }
    schedule  = { timezone = "America/Denver", days = ["mon", "tue", "wed", "thu", "fri"], on = "08:00", off = "20:00" }
  }

  assert {
    condition     = one(aws_backup_plan.snapshots[0].rule).schedule == "cron(0 21 ? * * *)"
    error_message = "a 20:00 stop snapshots at 21:00"
  }
}

run "snapshots_keep_the_last_n_days" {
  command = plan

  variables {
    snapshots = { enabled = true, keep = 7 }
  }

  assert {
    condition     = one(one(aws_backup_plan.snapshots[0].rule).lifecycle).delete_after == 7 && one(aws_backup_plan.snapshots[0].rule).target_vault_name == aws_backup_vault.snapshots[0].name
    error_message = "each daily snapshot is kept 7 days, in the node's vault"
  }
}

run "snapshots_back_up_only_the_data_volume" {
  command = plan

  variables {
    snapshots = { enabled = true }
  }

  assert {
    condition     = tolist(aws_backup_selection.snapshots[0].resources) == tolist([aws_ebs_volume.data.arn])
    error_message = "the backup takes the data volume, not the root volume"
  }
}

run "the_snapshot_vault_keeps_its_recovery_points" {
  command = plan

  variables {
    snapshots = { enabled = true }
  }

  assert {
    condition     = aws_backup_vault.snapshots[0].force_destroy == false && aws_backup_vault.snapshots[0].name == "acme-monitoring-snapshots"
    error_message = "a stray destroy never deletes the backups: the vault refuses while it holds any"
  }
}

run "rejects_a_domain_without_a_zone" {
  command = plan

  variables {
    domain = "grafana.example.com"
  }

  expect_failures = [var.zone_id]
}

run "rejects_an_invalid_name" {
  command = plan

  variables {
    name = "Acme Monitoring"
  }

  expect_failures = [var.name]
}

run "rejects_a_tiny_data_volume" {
  command = plan

  variables {
    data_volume_gb = 5
  }

  expect_failures = [var.data_volume_gb]
}

run "the_user_data_bootstraps_every_boot" {
  command = plan

  assert {
    condition     = strcontains(aws_instance.this.user_data, "COMPOSE_VERSION='v5.6.1'") && strcontains(aws_instance.this.user_data, "COMPOSE_SHA256='42cfa75f51ad0ccf290bad37899e0038a8c10a0069e85233ecc1d53e3ff1347d'")
    error_message = "the Compose plugin is pinned by version and checksum"
  }

  assert {
    condition     = strcontains(aws_instance.this.user_data, "PARAMETER_PREFIX='/acme-monitoring/node'") && strcontains(aws_instance.this.user_data, "DATA_VOLUME_ID='vol-0123456789abcdef0'") && strcontains(aws_instance.this.user_data, "CONFIG_BUCKET='acme-monitoring-config-123456789012'")
    error_message = "node.env names the parameters, the data volume and the config bucket"
  }

  assert {
    condition     = strcontains(aws_instance.this.user_data, "Before=docker.service") && strcontains(aws_instance.this.user_data, "OnUnitActiveSec=5min") && strcontains(aws_instance.this.user_data, "OnUnitActiveSec=6h")
    error_message = "the bootstrap runs before Docker at every boot; the reconciler every 5 minutes, the release check every 6 hours"
  }

  assert {
    condition     = startswith(aws_instance.this.user_data, "#cloud-config") && length(aws_instance.this.user_data) < 16384
    error_message = "cloud-config, within EC2's 16 KB user data limit"
  }
}

run "every_image_is_pinned_by_digest" {
  command = plan

  assert {
    condition     = alltrue([for s in values(yamldecode(local.bundle.files["compose.yaml"]).services) : strcontains(s.image, "@sha256:")])
    error_message = "every container image is pinned by digest"
  }
}

run "the_stack_has_memory_limits_and_restarts" {
  command = plan

  assert {
    condition     = alltrue([for s in values(yamldecode(local.bundle.files["compose.yaml"]).services) : s.restart == "unless-stopped" && can(s.mem_limit)])
    error_message = "every service restarts on its own and has a memory limit"
  }

  assert {
    condition     = yamldecode(local.bundle.files["compose.yaml"]).services.prometheus.mem_limit == "1g" && yamldecode(local.bundle.files["compose.yaml"]).services.grafana.mem_limit == "512m"
    error_message = "Prometheus may use 1 GB, Grafana 512 MB"
  }
}

run "without_a_domain_grafana_is_only_on_localhost" {
  command = plan

  assert {
    condition     = toset(keys(yamldecode(local.bundle.files["compose.yaml"]).services)) == toset(["grafana", "prometheus", "node-exporter", "cadvisor", "postgres", "postgres-exporter"])
    error_message = "without a domain there is no Caddy and no blackbox probe"
  }

  assert {
    condition     = yamldecode(local.bundle.files["compose.yaml"]).services.grafana.ports == ["127.0.0.1:3000:3000"]
    error_message = "Grafana is published on the loopback only, for a Session Manager port forward"
  }
}

run "with_a_domain_caddy_serves_grafana_and_blackbox_probes_it" {
  command = plan

  variables {
    domain  = "grafana.example.com"
    zone_id = "Z123"
  }

  assert {
    condition     = yamldecode(local.bundle.files["compose.yaml"]).services.caddy.ports == ["80:80", "443:443"] && !can(yamldecode(local.bundle.files["compose.yaml"]).services.grafana.ports)
    error_message = "Caddy publishes 80 and 443; Grafana publishes nothing"
  }

  assert {
    condition     = strcontains(local.bundle.files["caddy/Caddyfile"], "grafana.example.com {") && strcontains(local.bundle.files["caddy/Caddyfile"], "reverse_proxy grafana:3000") && strcontains(local.bundle.files["caddy/Caddyfile"], "@metrics path /metrics /metrics/*") && strcontains(local.bundle.files["caddy/Caddyfile"], "respond @metrics 404")
    error_message = "Caddy serves Grafana at the domain and hides its /metrics"
  }

  assert {
    condition     = one([for j in yamldecode(local.bundle.files["prometheus/prometheus.yml"]).scrape_configs : j.static_configs[0].targets if j.job_name == "blackbox"]) == ["https://grafana.example.com"]
    error_message = "the blackbox probe watches the public address and its certificate"
  }

  assert {
    condition     = yamldecode(local.bundle.files["compose.yaml"]).services.grafana.environment.GF_SERVER_ROOT_URL == "https://grafana.example.com" && yamldecode(local.bundle.files["compose.yaml"]).services.grafana.environment.GF_SECURITY_COOKIE_SECURE == "true"
    error_message = "Grafana knows its public address and sends secure cookies"
  }
}

run "prometheus_keeps_a_year_within_a_size_cap" {
  command = plan

  assert {
    condition     = contains(yamldecode(local.bundle.files["compose.yaml"]).services.prometheus.command, "--storage.tsdb.retention.time=365d") && contains(yamldecode(local.bundle.files["compose.yaml"]).services.prometheus.command, "--storage.tsdb.retention.size=12GB")
    error_message = "a year of metrics, never more than 12 GB"
  }

  assert {
    condition     = toset([for j in yamldecode(local.bundle.files["prometheus/prometheus.yml"]).scrape_configs : j.job_name]) == toset(["prometheus", "node", "cadvisor", "postgres", "grafana"])
    error_message = "Prometheus scrapes itself, the host, the containers, Postgres and Grafana"
  }
}

run "grafana_uses_postgres_and_provisioned_sources" {
  command = plan

  assert {
    condition     = yamldecode(local.bundle.files["compose.yaml"]).services.grafana.environment.GF_DATABASE_TYPE == "postgres" && yamldecode(local.bundle.files["compose.yaml"]).services.grafana.environment.GF_SECURITY_ADMIN_PASSWORD == "$${GF_SECURITY_ADMIN_PASSWORD:?}" && yamldecode(local.bundle.files["compose.yaml"]).services.postgres.environment.POSTGRES_PASSWORD == "$${POSTGRES_PASSWORD:?}"
    error_message = "Grafana keeps its state in Postgres and takes its admin password from the node's secrets"
  }

  assert {
    condition     = [for d in yamldecode(local.bundle.files["grafana/provisioning/datasources/datasources.yaml"]).datasources : "${d.uid}:${try(d.isDefault, false)}"] == ["prometheus:true", "cloudwatch:false"]
    error_message = "Prometheus (the default) and CloudWatch are provisioned"
  }

  assert {
    condition     = one([for d in yamldecode(local.bundle.files["grafana/provisioning/datasources/datasources.yaml"]).datasources : d.jsonData.defaultRegion if d.uid == "cloudwatch"]) == "us-east-1"
    error_message = "CloudWatch reads the node's region with the instance role"
  }

  assert {
    condition     = local.bundle.secrets == { GF_SECURITY_ADMIN_USER = "/acme/monitoring/grafana-admin-user", GF_SECURITY_ADMIN_PASSWORD = "/acme/monitoring/grafana-admin-password" } && local.bundle.generated == ["POSTGRES_PASSWORD"]
    error_message = "the bundle names the secrets to read and the one to generate"
  }
}

run "a_service_is_recreated_only_when_its_files_change" {
  command = plan

  assert {
    condition     = yamldecode(local.bundle.files["compose.yaml"]).services.prometheus.labels["monitoring.config-hash"] == sha256(local.bundle.files["prometheus/prometheus.yml"])
    error_message = "a service's label hashes the files it mounts, so compose recreates exactly what changed"
  }
}

run "mounts_resolve_through_the_stable_current_link" {
  command = plan

  variables {
    domain  = "grafana.example.com"
    zone_id = "Z123"
  }

  assert {
    condition = (contains(yamldecode(local.bundle.files["compose.yaml"]).services.prometheus.volumes, "/data/config/current/prometheus:/etc/prometheus:ro")
      && contains(yamldecode(local.bundle.files["compose.yaml"]).services.grafana.volumes, "/data/config/current/grafana/provisioning:/etc/grafana/provisioning:ro")
      && contains(yamldecode(local.bundle.files["compose.yaml"]).services.caddy.volumes, "/data/config/current/caddy/Caddyfile:/etc/caddy/Caddyfile:ro")
    && contains(yamldecode(local.bundle.files["compose.yaml"]).services["blackbox-exporter"].volumes, "/data/config/current/blackbox:/etc/blackbox_exporter:ro"))
    error_message = "config mounts go through /data/config/current, so a new release does not change a service's own definition; only its config-hash label does"
  }

  assert {
    condition     = !anytrue([for s in values(yamldecode(local.bundle.files["compose.yaml"]).services) : anytrue([for v in try(s.volumes, []) : startswith(v, "./")])])
    error_message = "no mount is relative to the release folder"
  }
}

run "the_bundle_carries_grafanas_files" {
  command = plan

  assert {
    condition     = alltrue([for path, content in module.grafana.files : try(local.bundle.files[path] == content, false)])
    error_message = "every file the Grafana config module renders goes into the bundle unchanged"
  }

  assert {
    condition     = !contains(keys(local.bundle.files), "grafana/dashboards/.keep")
    error_message = "the dashboards folder no longer needs a placeholder"
  }
}

run "rejects_an_extra_dashboard_outside_a_folder" {
  command = plan

  variables {
    extra_dashboards = { "extra.json" = "{\"uid\": \"x\", \"title\": \"X\"}" }
  }

  expect_failures = [var.extra_dashboards]
}

run "rejects_an_extra_rules_name_grafana_cant_file" {
  command = plan

  variables {
    extra_alert_rules = { "My Rules" = "apiVersion: 1" }
  }

  expect_failures = [var.extra_alert_rules]
}

run "the_default_thresholds_are_the_specs" {
  command = plan

  assert {
    condition = jsonencode(var.thresholds) == jsonencode({
      container_restarts        = { critical = 3, warning = 1 }
      cost_sync_hours           = { critical = 6, warning = 2 }
      anomaly_ratio             = { critical = 4, warning = 2 }
      untagged_daily_usd        = { warning = 0.5 }
      aws_charge_days           = { critical = 5, warning = 3 }
      databricks_delivery_hours = { critical = 60, warning = 36 }
      normalizer_hours          = { critical = 12, warning = 3 }
      cpu_credits_percent       = { critical = 5, warning = 25 }
      cpu_percent               = { critical = 85, warning = 60 }
      disk_full_days            = { critical = 2, warning = 7 }
      disk_percent              = { critical = 90, warning = 70 }
      inodes_percent            = { critical = 90, warning = 70 }
      memory_percent            = { critical = 90, warning = 70 }
      os_release_update_days    = { warning = 7 }
      prometheus_history_days   = { warning = 90 }
      prometheus_size_percent   = { warning = 85 }
      swap_percent              = { critical = 75, warning = 25 }
      tls_days                  = { critical = 3, warning = 14 }
    })
    error_message = "the thresholds default to spec 6.8's table (and the owner's history rule)"
  }
}

run "rejects_thresholds_in_the_wrong_order" {
  command = plan

  variables {
    thresholds = { cpu_percent = { warning = 90, critical = 80 } }
  }

  expect_failures = [var.thresholds]
}

run "rejects_lower_is_worse_thresholds_in_the_wrong_order" {
  command = plan

  variables {
    thresholds = { tls_days = { warning = 3, critical = 14 } }
  }

  expect_failures = [var.thresholds]
}

run "rejects_a_fractional_restart_count" {
  command = plan

  variables {
    thresholds = { container_restarts = { warning = 1.5, critical = 3 } }
  }

  expect_failures = [var.thresholds]
}

run "rejects_a_percentage_over_100" {
  command = plan

  variables {
    thresholds = { memory_percent = { warning = 70, critical = 120 } }
  }

  expect_failures = [var.thresholds]
}

run "with_slack_the_node_reads_each_webhook" {
  command = plan

  variables {
    slack = { channels = { platform = "/acme/monitoring/slack/platform", costs = "/acme/monitoring/slack/costs" }, routes = { host = "platform", pipeline = "platform", cost = "costs" } }
  }

  assert {
    condition     = contains(one([for s in jsondecode(aws_iam_role_policy.this.policy).Statement : s.Resource if s.Sid == "ReadTheParameters"]), "arn:aws:ssm:us-east-1:123456789012:parameter/acme/monitoring/slack/platform") && contains(one([for s in jsondecode(aws_iam_role_policy.this.policy).Statement : s.Resource if s.Sid == "ReadTheParameters"]), "arn:aws:ssm:us-east-1:123456789012:parameter/acme/monitoring/slack/costs")
    error_message = "the role may read each webhook parameter"
  }

  assert {
    condition     = local.bundle.secrets.SLACK_WEBHOOK_COSTS == "/acme/monitoring/slack/costs" && local.bundle.secrets.SLACK_WEBHOOK_PLATFORM == "/acme/monitoring/slack/platform"
    error_message = "the reconciler reads each webhook into its variable"
  }

  assert {
    condition     = yamldecode(local.bundle.files["compose.yaml"]).services.grafana.environment.SLACK_WEBHOOK_PLATFORM == "$${SLACK_WEBHOOK_PLATFORM:?}" && yamldecode(local.bundle.files["compose.yaml"]).services.grafana.environment.SLACK_WEBHOOK_COSTS == "$${SLACK_WEBHOOK_COSTS:?}"
    error_message = "Grafana gets each webhook in its environment, and compose refuses to start it without one"
  }
}

run "rejects_a_route_to_an_unknown_channel" {
  command = plan

  variables {
    slack = { channels = { platform = "/acme/slack/platform" }, routes = { host = "nope" } }
  }

  expect_failures = [var.slack]
}

run "rejects_routes_without_host" {
  command = plan

  variables {
    slack = { channels = { platform = "/acme/slack/platform" }, routes = { cost = "platform" } }
  }

  expect_failures = [var.slack]
}

run "rejects_an_unknown_area" {
  command = plan

  variables {
    slack = { channels = { platform = "/acme/slack/platform" }, routes = { host = "platform", billing = "platform" } }
  }

  expect_failures = [var.slack]
}

run "rejects_a_bad_channel_name" {
  command = plan

  variables {
    slack = { channels = { Platform_1 = "/acme/slack/platform" }, routes = { host = "Platform_1" } }
  }

  expect_failures = [var.slack]
}

run "rejects_a_relative_parameter" {
  command = plan

  variables {
    slack = { channels = { platform = "acme/slack/platform" }, routes = { host = "platform" } }
  }

  expect_failures = [var.slack]
}

run "rejects_a_prometheus_size_cap_of_zero" {
  command = plan

  variables {
    prometheus_retention = { size_gb = 0 }
  }

  expect_failures = [var.prometheus_retention]
}

run "with_cost_the_node_reads_only_normalized_data" {
  command = plan

  variables {
    cost = { bucket = "acme-billing" }
  }

  assert {
    condition     = one([for s in jsondecode(aws_iam_role_policy.this.policy).Statement : s if s.Sid == "ReadNormalizedCost"]).Action == "s3:GetObject" && one([for s in jsondecode(aws_iam_role_policy.this.policy).Statement : s if s.Sid == "ReadNormalizedCost"]).Resource == "arn:aws:s3:::acme-billing/normalized/*"
    error_message = "the node reads the normalized objects and nothing else in the bucket"
  }

  assert {
    condition     = one([for s in jsondecode(aws_iam_role_policy.this.policy).Statement : s if s.Sid == "ListNormalizedCost"]).Action == "s3:ListBucket" && one([for s in jsondecode(aws_iam_role_policy.this.policy).Statement : s if s.Sid == "ListNormalizedCost"]).Resource == "arn:aws:s3:::acme-billing" && jsonencode(one([for s in jsondecode(aws_iam_role_policy.this.policy).Statement : s if s.Sid == "ListNormalizedCost"]).Condition) == jsonencode({ StringLike = { "s3:prefix" = ["normalized/*"] } })
    error_message = "and lists only under normalized/"
  }
}

run "without_cost_the_node_reads_no_billing_data" {
  command = plan

  assert {
    condition     = length([for s in jsondecode(aws_iam_role_policy.this.policy).Statement : s if contains(["ReadNormalizedCost", "ListNormalizedCost"], s.Sid)]) == 0 && !contains(keys(local.bundle.files), "cost-sync/config.json") && local.bundle.generated == ["POSTGRES_PASSWORD"]
    error_message = "a host-only node has no cost access, config or reader secret"
  }
}

run "with_cost_the_bundle_configures_cost_sync" {
  command = plan

  variables {
    cost = { bucket = "acme-billing" }
  }

  assert {
    condition     = jsonencode(jsondecode(local.bundle.files["cost-sync/config.json"])) == jsonencode({ bucket = "acme-billing", budgets = { accounts = {}, projects = {}, total = null }, prefix = "normalized", databricks_workspace_tag = "Workspace", providers = ["aws", "databricks"], run_join_tags = ["RunId", "TaskId"] })
    error_message = "cost-sync reads its bucket, prefix, providers and join tags from the bundle"
  }

  assert {
    condition     = local.bundle.files["cost-sync/monitoring-cost-sync.py"] == file("files/monitoring-cost-sync.py")
    error_message = "the script itself travels in the bundle, so a change to it never replaces the instance"
  }

  assert {
    condition     = contains(local.bundle.generated, "COST_READER_PASSWORD") && yamldecode(local.bundle.files["compose.yaml"]).services.grafana.environment.COST_READER_PASSWORD == "$${COST_READER_PASSWORD:?}"
    error_message = "Grafana's read-only cost user gets a generated password"
  }
}

run "the_user_data_runs_cost_sync_every_30_minutes" {
  command = plan

  assert {
    condition     = strcontains(aws_instance.this.user_data, "monitoring-cost-sync.timer") && strcontains(aws_instance.this.user_data, "OnUnitActiveSec=30min") && strcontains(aws_instance.this.user_data, "OnBootSec=2min")
    error_message = "cost-sync runs at boot and every 30 minutes"
  }

  assert {
    condition     = strcontains(aws_instance.this.user_data, "ConditionPathExists=/data/config/current/cost-sync/monitoring-cost-sync.py") && strcontains(aws_instance.this.user_data, "ExecStart=/usr/bin/python3 /data/config/current/cost-sync/monitoring-cost-sync.py")
    error_message = "it runs the bundle's script, and is skipped while cost is off"
  }
}

run "rejects_an_unknown_provider" {
  command = plan

  variables {
    cost = { bucket = "acme-billing", providers = ["gcp"] }
  }

  expect_failures = [var.cost]
}

run "rejects_a_prefix_with_slashes" {
  command = plan

  variables {
    cost = { bucket = "acme-billing", normalized_prefix = "/normalized/" }
  }

  expect_failures = [var.cost]
}

run "rejects_pipeline_thresholds_in_the_wrong_order" {
  command = plan

  variables {
    thresholds = { normalizer_hours = { warning = 12, critical = 3 } }
  }

  expect_failures = [var.thresholds]
}

run "with_budgets_cost_sync_gets_them" {
  command = plan

  variables {
    cost = { bucket = "acme-billing", budgets = { total = 100, projects = { alpha = 50 } } }
  }

  assert {
    condition     = jsonencode(jsondecode(local.bundle.files["cost-sync/config.json"]).budgets) == jsonencode({ accounts = {}, projects = { alpha = 50 }, total = 100 })
    error_message = "cost-sync gets the budgets to write into cost.budgets"
  }
}

run "rejects_a_zero_budget" {
  command = plan

  variables {
    cost = { bucket = "acme-billing", budgets = { total = 0 } }
  }

  expect_failures = [var.cost]
}

run "rejects_a_negative_anomaly_floor" {
  command = plan

  variables {
    cost = { bucket = "acme-billing", anomaly_floor_usd = -1 }
  }

  expect_failures = [var.cost]
}

run "rejects_a_workspace_tag_with_a_comma" {
  command = plan

  variables {
    cost = { bucket = "acme-billing", databricks_workspace_tag = "Workspace,Name" }
  }

  expect_failures = [var.cost]
}

run "rejects_an_anomaly_ratio_of_one" {
  command = plan

  variables {
    thresholds = { anomaly_ratio = { warning = 1, critical = 4 } }
  }

  expect_failures = [var.thresholds]
}

run "without_a_schedule_the_node_runs_all_day" {
  command = plan

  assert {
    condition     = length(aws_scheduler_schedule.start) == 0 && length(aws_scheduler_schedule.stop) == 0 && length(aws_iam_role.schedule) == 0
    error_message = "no schedule means always on: nothing starts or stops the node"
  }
}

run "a_schedule_starts_and_stops_the_node" {
  command = plan

  variables {
    schedule = { timezone = "America/Denver", days = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"], on = "08:00", off = "24:00" }
  }

  assert {
    condition     = aws_scheduler_schedule.start[0].schedule_expression == "cron(0 8 ? * MON,TUE,WED,THU,FRI,SAT,SUN *)" && aws_scheduler_schedule.stop[0].schedule_expression == "cron(0 0 ? * TUE,WED,THU,FRI,SAT,SUN,MON *)"
    error_message = "it starts at 08:00 each day, and a 24:00 stop fires at 00:00 on each next day"
  }

  assert {
    condition     = alltrue([for s in [aws_scheduler_schedule.start[0], aws_scheduler_schedule.stop[0]] : s.schedule_expression_timezone == "America/Denver" && s.flexible_time_window[0].mode == "OFF"])
    error_message = "both run on the dot, in the schedule's time zone"
  }

  assert {
    condition     = aws_scheduler_schedule.start[0].target[0].arn == "arn:aws:scheduler:::aws-sdk:ec2:startInstances" && aws_scheduler_schedule.stop[0].target[0].arn == "arn:aws:scheduler:::aws-sdk:ec2:stopInstances" && alltrue([for s in [aws_scheduler_schedule.start[0], aws_scheduler_schedule.stop[0]] : s.target[0].input == jsonencode({ InstanceIds = ["i-0123456789abcdef0"] })])
    error_message = "they start and stop this one instance"
  }
}

run "an_evening_stop_keeps_its_days" {
  command = plan

  variables {
    schedule = { timezone = "America/Denver", days = ["mon", "tue", "wed", "thu", "fri"], on = "08:00", off = "20:00" }
  }

  assert {
    condition     = aws_scheduler_schedule.stop[0].schedule_expression == "cron(0 20 ? * MON,TUE,WED,THU,FRI *)"
    error_message = "a stop before midnight runs on the same days as the start"
  }
}

run "the_scheduler_may_start_and_stop_only_this_instance" {
  command = plan

  variables {
    schedule = { timezone = "America/Denver", days = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"], on = "08:00", off = "24:00" }
  }

  assert {
    condition     = jsonencode([for st in jsondecode(aws_iam_role_policy.schedule[0].policy).Statement : [st.Effect, sort(flatten([st.Action])), flatten([st.Resource])]]) == jsonencode([["Allow", ["ec2:StartInstances", "ec2:StopInstances"], [aws_instance.this.arn]]])
    error_message = "the scheduler's role starts and stops this instance, and nothing else"
  }
}

run "rejects_half_hours" {
  command = plan

  variables {
    schedule = { timezone = "UTC", days = ["mon"], on = "08:30", off = "20:00" }
  }

  expect_failures = [var.schedule]
}

run "rejects_an_overnight_window" {
  command = plan

  variables {
    schedule = { timezone = "UTC", days = ["mon"], on = "22:00", off = "06:00" }
  }

  expect_failures = [var.schedule]
}

run "rejects_fewer_than_4_hours_on" {
  command = plan

  variables {
    schedule = { timezone = "UTC", days = ["mon"], on = "08:00", off = "11:00" }
  }

  expect_failures = [var.schedule]
}

run "rejects_an_unknown_day" {
  command = plan

  variables {
    schedule = { timezone = "UTC", days = ["funday"], on = "08:00", off = "20:00" }
  }

  expect_failures = [var.schedule]
}

run "rejects_a_repeated_day" {
  command = plan

  variables {
    schedule = { timezone = "UTC", days = ["mon", "mon"], on = "08:00", off = "20:00" }
  }

  expect_failures = [var.schedule]
}

run "rejects_no_days" {
  command = plan

  variables {
    schedule = { timezone = "UTC", days = [], on = "08:00", off = "20:00" }
  }

  expect_failures = [var.schedule]
}
