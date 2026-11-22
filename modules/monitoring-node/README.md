# monitoring-node

Part of [`Jaws-Platform/jaws-monitoring/aws`](https://registry.terraform.io/modules/Jaws-Platform/jaws-monitoring/aws/latest) · [Registry](https://registry.terraform.io/modules/Jaws-Platform/jaws-monitoring/aws/latest/submodules/monitoring-node) · [Source](https://github.com/Jaws-Platform/terraform-aws-jaws-monitoring/tree/main/modules/monitoring-node)

One small Graviton instance running the monitoring stack in Docker Compose:
Grafana (on Postgres), Prometheus, node-exporter, cAdvisor and
postgres-exporter, and, with a `domain`, Caddy for HTTPS and a blackbox probe
of the public address. It watches itself: a host health dashboard, alert
rules in warning and critical pairs, and Slack notifications routed by area.
Its state lives on a separate data volume, and its configuration arrives as a
content-addressed bundle, so a dashboard or alerting change never replaces
the instance.

What it creates:

- **the instance**: the Amazon Linux 2023 arm64 image named `ami_name`,
  IMDSv2 only (hop limit 2, so containers reach the instance role), standard
  CPU credits, an encrypted gp3 root volume, a public IPv4 address, a role
  with Session Manager and nothing else to reach it by;
- **the data volume** `<name>-data` (encrypted gp3), mounted at `/data` and
  kept when the instance is replaced, with optional daily snapshots;
- **the security group**: no ingress at all without a `domain`; with one,
  443 and 80 (Let's Encrypt and the redirect) only;
- **the DNS record** (with a `domain`): the node upserts its own address at
  every boot, because it changes on every stop and start; its role may
  change only that one A record;
- **the config bucket** `<name>-config-<account>` and the parameters
  `/<name>/node/config-bundle`, `status` and `running-config`.

Every resource carries `Name` and `Component = "monitoring"`; every other tag
comes from the caller's provider `default_tags`.

## How a change rolls out

Terraform renders every file the stack runs with (`compose.yaml`,
Prometheus, Caddy, Grafana provisioning) into one JSON bundle, stores it at
`bundles/<sha256>.json` and names it in `/<name>/node/config-bundle`. The
reconciler on the node (`monitoring-reconcile`, at boot and every 5 minutes)
converges to it:

1. it first starts the current release with the values it last ran with, so
   the stack comes up even when S3 or SSM can't be reached;
2. it reads the bundle name and the secrets the bundle names; if neither
   changed, that is all. Otherwise it downloads the bundle and makes the
   values it generates once (the Postgres password, kept on the data
   volume);
3. it writes the new release and pulls its images, retried five times; until
   all of that worked, the running stack is untouched;
4. it saves the values, swaps the release in and runs `docker compose up -d`;
   config is mounted through `/data/config/current` and each service is
   labelled with a hash of the files it mounts, so only the services whose
   files changed are recreated. A rotated Grafana admin password is then
   applied with `grafana cli admin reset-admin-password`.

What the node runs is recorded on its root volume, with the values it runs
with, so a replaced instance always reconciles in full.

`/<name>/node/status` says how it went, and is written only when it changes:
`ok`, or `failed:missing secret <parameter>`, `failed:bundle <problem>`,
`failed:pull`, `failed:up` (also when the running stack will not start),
`failed:password-reset` or `failed:internal <error>`. `monitoring-reconcile
--force` reconciles in full even when nothing changed. To
apply a change at once instead of within 5 minutes, start
`monitoring-reconcile.service` through Session Manager.

Changing the bootstrap (`ami_name`, the Compose plugin, the scripts)
replaces the instance; the new one reattaches the data volume and carries
on. Container images are pinned by digest; a version bump is a bundle
change, not an instance replacement.

## Before the first apply

Set the two SecureString parameters `grafana_admin` names, the admin user
name and password, encrypted with the default `aws/ssm` key (the role is
granted no other key). Until they exist the node reports
`failed:missing secret <parameter>` and starts nothing new. To rotate the
password, change the parameter: within 5 minutes the node applies it. The
role can read only the parameters the module names, not the account's other
SecureStrings: it gets Session Manager's own actions, not the
`AmazonSSMManagedInstanceCore` policy.

## Reaching Grafana

With a `domain`, at `https://<domain>`. Without one, through a port forward:

```sh
aws ssm start-session --target <instance_id> \
  --document-name AWS-StartPortForwardingSession \
  --parameters portNumber=3000,localPortNumber=3000
```

## What the node watches

**Monitoring node · Host health** (folder `Monitoring`) shows the last 6
hours, refreshed every 30 seconds. Tiles across the top: CPU, memory, root
and data disk, CPU credits (burstable types), targets up and uptime. Then a
row each for CPU, memory (swap, OOM kills, pressure, memory by container),
disk (used, days until full, inodes, Prometheus against its cap, history
kept, Postgres size, I/O), services (scrape targets, container restarts, CPU
by container, and with a `domain` the TLS certificate and the HTTPS probe)
and patching (a newer Amazon Linux release, the running release, the last
boot). Tiles turn yellow and red, and graphs draw dashed lines, at the same
numbers the alert rules use.

The alert rules (folder `Monitoring`, label `area = host`), with their
defaults:

| Rule | Warning | Critical | Waits | `thresholds` |
|---|---|---|---|---|
| CPU used, 10-minute average | 60 % | 85 % | 2 min | `cpu_percent` |
| CPU credit balance, of the type's maximum (burstable types) | below 25 % | below 5 % | 15 min | `cpu_credits_percent` |
| Memory used, 5-minute average | 70 % | 90 % | 2 min | `memory_percent` |
| Swap used, 15-minute average | 25 % | 75 % | 2 min | `swap_percent` |
| OOM kill, last 10 minutes | | any | 2 min | |
| Disk used, each volume | 70 % | 90 % | 5 min | `disk_percent` |
| Disk full at the last 24 hours' growth | within 7 days | within 2 days | 30 min | `disk_full_days` |
| Inodes used, each volume | 70 % | 90 % | 5 min | `inodes_percent` |
| Prometheus cap cutting history: above 85 % of its cap *and* fewer than 90 days kept | fewer than 90 days | | 15 min | `prometheus_history_days`, `prometheus_size_percent` |
| Scrape target down | | any | 2 min | |
| Container restarts by Docker, 15 minutes | 1 | 3 | 2 min | `container_restarts` |
| TLS certificate expiry (with a `domain`) | within 14 days | within 3 days | 2 min | `tls_days` |
| Grafana rule-evaluation failures, 10 minutes | any, for 12 minutes | | 12 min | |
| Newer Amazon Linux 2023 release available (reminded once a day) | for 7 days | | 2 min | `os_release_update_days` |

Every rule waits at least 2 minutes, and the rule-evaluation failures rule
12, longer than its 10-minute window, so the restart of Prometheus or Grafana
that a config change causes doesn't post. A rule that stops applying (a
`domain` removed, a type without CPU credits) is deleted from Grafana, not
left firing with its old numbers.

### Thresholds

Override any of them; the rest keep their defaults:

```hcl
thresholds = {
  cpu_percent  = { warning = 70, critical = 90 }
  disk_percent = { warning = 75, critical = 90 }
}
```

### Slack

```hcl
slack = {
  channels = {
    platform = "/acme/monitoring/slack/platform" # SecureString: the incoming-webhook URL
    costs    = "/acme/monitoring/slack/costs"
  }
  routes = { host = "platform", pipeline = "platform", cost = "costs" }
}
```

Each channel is a contact point; each area (`host`, `pipeline`, `cost`) goes
to its channel, and `host` is required: everything else falls back to it.
Messages are grouped by folder and rule, include resolved ones, and repeat
every 4 hours while an alert keeps firing (a due AMI bump once a day). The webhook URLs never enter the
bundle: the node reads each parameter into Grafana's environment.

- **Adding a channel:** create its webhook parameter (SecureString, default
  `aws/ssm` key), add one line to `channels`, and route an area to it.
- **Rotating a webhook:** change the parameter; within 5 minutes the node
  restarts Grafana with the new one.
- Without `slack`, alerts show in Grafana only, and Grafana's notification
  policy is reset to its default.

### Silences

Rules are provisioned, so they are read-only in Grafana; to change one for
good, change its threshold. Silences are allowed: before a planned
expensive run or a maintenance, silence the rule under **Alerting →
Silences**, with an end time.

### More dashboards and rules

`extra_dashboards` maps `"<Folder>/<name>.json"` to a dashboard's JSON (it
needs a `uid` and a `title`); the folder is created in Grafana.
`extra_alert_rules` maps a name to a Grafana alerting provisioning document
(YAML), provisioned as `rules-extra-<name>.json`. Every rule needs labels
`area` (`host`, `pipeline` or `cost`) and `severity` (`warning` or
`critical`), and links a panel with both `__dashboardUid__` and
`__panelId__` or neither. A lone `$` only works in annotations and query
models, where Grafana doesn't expand it; elsewhere write `$$`. Durations are
Grafana's (`2m`, `1h30m`), a group's `interval` sits on its 10-second grid,
states are `OK`, `NoData`, `Alerting` or `KeepLast` (`Error` for
`execErrState`), every query has a `refId`, a `datasourceUid` and a `model`,
and no uid is one of the module's own host rules (`host-<rule>-<severity>`).
The plan fails if a
rule breaks any of this, because Grafana would otherwise exit at startup:
no dashboards, no alerts. To remove an extra rule, keep its uid
under `deleteRules` in its document; Grafana keeps a provisioned rule until
it is told to delete it.

### Testing it

`scripts/check-module.sh modules/monitoring-node` runs the Terraform tests,
the reconciler, cost-sync and release-check tests, and two Docker tests:

- **the cost-sync test** runs the real script against the pinned Postgres
  and the normalizer's contract fixtures;
- **the Grafana smoke test** checks every PromQL query with `promtool`, starts
  the pinned Grafana on what the module renders (next to a Postgres the real
  cost-sync set up), and compares Grafana's API with the files. Then it
  renders a changed configuration and checks that what was removed is gone.

## Cost data

With `cost`, the node keeps a `cost` database in its Postgres, filled from
the billing bucket's `normalized/` layer, the only part of the bucket its
role can read:

```hcl
cost = {
  bucket = "acme-billing"
  # normalized_prefix = "normalized"
  # providers         = ["aws", "databricks"]   # which freshness alerts apply
  # run_join_tags     = ["RunId", "TaskId"]     # the tags a run's cost rows carry
  budgets = {                                  # monthly, in USD
    total    = 100
    projects = { braveheart = 60 }
    accounts = { production = 80 }             # by account id or name
  }
  # anomaly_floor_usd = 2                      # a day must also be this much over its norm
}
```

**cost-sync** (a systemd timer, at boot and every 30 minutes) loads the
billing-normalizer's CSV twins (`data.csv.gz`).

- Each output whose ETag changed is loaded in one transaction, so it is
  never doubled or half there.
- An output that is gone loses its rows, and one bad output never stops the
  rest.
- It records the normalizer's `_runs/latest.json`, and writes the textfile
  metrics the pipeline alerts read.
- Its script and config travel in the bundle, so a change to them never
  replaces the instance.
- `journalctl -u monitoring-cost-sync` shows each run.

**The database** is a cache of the bucket: a schema version change, or a lost
data volume, rebuilds it from `normalized/`. Grafana reads it through the
`Cost` data source as the read-only `cost_reader`. Ad hoc, from a Session
Manager shell:

```sh
sudo docker exec -it monitoring-postgres-1 psql -U monitoring -d cost
```

| Object | What it holds |
|---|---|
| `cost.lines` | one row per normalized cost row: the FOCUS columns in snake_case, `tags` (jsonb), `project`, `component`, `environment`, `serverless`, `source` |
| `cost.run_events` | one row per task-run event (`started`, `finished`, `swept`) |
| `cost.task_runs` | one row per run: its launch metadata, `started_at`, `ended_at`, `outcome` (`swept`, or null while running) |
| `cost.task_run_costs` | each run's billed cost: the cost rows that carry its join tags |
| `cost.loads`, `cost.normalizer_runs` | what was loaded, and the normalizer runs seen |
| `cost.daily` | spend per UTC day, provider, account, project (`(untagged)` without one), environment, service and charge category, with whether the day is `complete` |
| `cost.month_to_date` | per scope (`total`, each project, each account): month to date, the forecast, the budget, and both as a share of it |
| `cost.anomalies` | the newest day's spend per total, project and service against the median of the 14 complete days before it |
| `cost.untagged`, `cost.untagged_new` | untagged spend (tax and credits aside), and the newest day's pairs with none in the 14 days before |
| `cost.budgets`, `cost.as_of` | the budgets from the `cost` input (rewritten every run), and the newest complete day |

**Days and the forecast.**

- Days are UTC calendar days, because AWS bills in UTC. A day is complete 48 hours after it ends; until then its charges are still arriving.
- The month-end forecast is the month's complete days, plus the last 7 complete days' average for every day still to come. A partial day is replaced by the average, not counted short.

**The pipeline alerts** (label `area = pipeline`, on the host dashboard's
Pipeline row):

| Rule | Warning | Critical | `thresholds` |
|---|---|---|---|
| Cost sync late | 2 h | 6 h | `cost_sync_hours` |
| Normalizer late (no successful run) | 3 h | 12 h | `normalizer_hours` |
| Normalizer run failed | | the last run failed | |
| AWS charges stale (newest charge loaded) | 3 days | 5 days | `aws_charge_days` |
| Databricks delivery stale | 36 h | 60 h | `databricks_delivery_hours` |
| Task run possibly leaked (no end, an hour past its max hours) | | any | |
| Task run over its ceiling (billed cost; runs from the last 7 days, posted once a week) | | any | |

Until any data has arrived, each clock starts when the node first ran
cost-sync. A new node isn't alarmed in its first hours, but is once data
never comes.

**The cost alerts** (label `area = cost`, folder `Cost`, every 5 minutes) are
SQL on the cost database, one alert per row:

| Rule | Warning | Critical | Set by |
|---|---|---|---|
| Budget: month-end forecast | over 100 % of a budget | | `cost.budgets` |
| Budget: month to date | | over 100 % of a budget | `cost.budgets` |
| Daily spend anomaly (the total and each project): the newest day against the median of its 14 complete days before, and over `anomaly_floor_usd` above it | 2× | 4× | `thresholds.anomaly_ratio`, `cost.anomaly_floor_usd` |
| New untagged spend: an account and service with none in the 14 days before | over $0.50 | | `thresholds.untagged_daily_usd` |

A planned expensive run will trip the anomaly alert: silence it first (see
Silences). A brand-new project has no median, so only the total can alert on
its first days.

**Cost · Overview** (folder `Cost`) shows the last 90 days, filtered by
provider, account, project and environment. Tiles across the top: month to
date, forecast and spend against the total budget, yesterday, the month-on-
month change, untagged spend and the newest complete day. Below them, the
trend, where the money goes, the budgets, the biggest movers and the
untagged spend.

## Recovery

| Event | What happens | What's lost |
|---|---|---|
| Stop and start | The disks persist; the stack comes back, and DNS follows the new address | Metrics for the time it was off |
| Reboot or EC2 recovery | Same disks, same instance | Minutes of metrics |
| Instance replaced | The new instance reattaches the data volume and carries on | Minutes of metrics |
| Data volume lost | Dashboards and alerts are reprovisioned from the bundle, and cost-sync rebuilds the cost database from `normalized/`; Grafana users other than the admin must be added again | Prometheus history since the last snapshot |

## Usage

```hcl
module "monitoring_node" {
  source  = "Jaws-Platform/jaws-monitoring/aws//modules/monitoring-node"
  version = "0.5.0" # x-release-please-version

  name      = "acme-monitoring"
  vpc_id    = "vpc-0123456789abcdef0"
  subnet_id = "subnet-0123456789abcdef0"
  ami_name  = "al2023-ami-2023.12.20261026.1-kernel-6.18-arm64"
  domain    = "grafana.example.com"
  zone_id   = "Z0123456789ABCDEFGHIJ"

  grafana_admin = {
    user_parameter     = "/acme/monitoring/grafana-admin-user"
    password_parameter = "/acme/monitoring/grafana-admin-password"
  }

  slack = {
    channels = { platform = "/acme/monitoring/slack/platform" }
    routes   = { host = "platform" }
  }

  cost = { bucket = "acme-billing" }
}
```

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| terraform | >= 1.11 |
| aws | ~> 6.0 |

## Providers

| Name | Version |
| ---- | ------- |
| aws | ~> 6.0 |

## Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| grafana | ./grafana | n/a |

## Resources

| Name | Type |
| ---- | ---- |
| [aws_dlm_lifecycle_policy.snapshots](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/dlm_lifecycle_policy) | resource |
| [aws_ebs_volume.data](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ebs_volume) | resource |
| [aws_iam_instance_profile.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_instance_profile) | resource |
| [aws_iam_role.snapshots](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy_attachment.snapshots](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_instance.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/instance) | resource |
| [aws_route53_record.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route53_record) | resource |
| [aws_s3_bucket.config](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket) | resource |
| [aws_s3_bucket_lifecycle_configuration.config](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_lifecycle_configuration) | resource |
| [aws_s3_bucket_ownership_controls.config](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_ownership_controls) | resource |
| [aws_s3_bucket_public_access_block.config](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_public_access_block) | resource |
| [aws_s3_bucket_server_side_encryption_configuration.config](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_server_side_encryption_configuration) | resource |
| [aws_s3_bucket_versioning.config](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_versioning) | resource |
| [aws_s3_object.bundle](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_object) | resource |
| [aws_security_group.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
| [aws_ssm_parameter.config_bundle](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ssm_parameter) | resource |
| [aws_ssm_parameter.running_config](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ssm_parameter) | resource |
| [aws_ssm_parameter.status](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ssm_parameter) | resource |
| [aws_volume_attachment.data](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/volume_attachment) | resource |
| [aws_vpc_security_group_egress_rule.all](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_egress_rule) | resource |
| [aws_vpc_security_group_ingress_rule.web](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_ingress_rule) | resource |
| [aws_ami.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/ami) | data source |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |
| [aws_subnet.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/subnet) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| ami\_name | The exact name of the Amazon Linux 2023 arm64 image to run, e.g. `al2023-ami-2023.12.20261026.1-kernel-6.18-arm64`. Changing it replaces the instance; the data volume is reattached. | `string` | n/a | yes |
| grafana\_admin | The SSM SecureString parameters (default aws/ssm key) holding Grafana's admin user name and password. Set them before the first apply. The node checks them every 5 minutes; a changed password is applied with Grafana's admin password reset. | <pre>object({<br/>    user_parameter     = string<br/>    password_parameter = string<br/>  })</pre> | n/a | yes |
| name | Names the instance, its role, security group, data volume (`<name>-data`), config bucket (`<name>-config-<account>`) and parameters (`/<name>/node/…`). | `string` | n/a | yes |
| subnet\_id | A public subnet for the node. The data volume is created in its availability zone, so moving the node to another zone means a new volume. | `string` | n/a | yes |
| vpc\_id | The VPC of the node's subnet. | `string` | n/a | yes |
| acme\_email | Optional contact address for Let's Encrypt. | `string` | `null` | no |
| cost | The cost data, read from the billing bucket's normalized/ layer (the billing-normalizer's CSV twins): bucket, the normalizer's prefix, the providers expected there (for the staleness alerts), the tags a task run's cost rows are joined on, monthly budgets in USD (total, per project, per account by id or name), and the anomaly floor (the day's spend must also be this many USD over its 14-day median). null for a host-only node. With it, cost-sync keeps the cost database on the node and Grafana reads it. | <pre>object({<br/>    bucket            = string<br/>    normalized_prefix = optional(string, "normalized")<br/>    providers         = optional(set(string), ["aws", "databricks"])<br/>    run_join_tags     = optional(list(string), ["RunId", "TaskId"])<br/>    budgets = optional(object({<br/>      total    = optional(number)<br/>      projects = optional(map(number), {})<br/>      accounts = optional(map(number), {})<br/>    }), {})<br/>    anomaly_floor_usd = optional(number, 2)<br/>  })</pre> | `null` | no |
| data\_volume\_gb | Size of the data volume: Prometheus, Postgres, Grafana and Caddy's state, kept when the instance is replaced. | `number` | `30` | no |
| domain | The name Grafana is served at over HTTPS (Caddy, Let's Encrypt). Null: no ingress at all; reach Grafana through a Session Manager port forward. | `string` | `null` | no |
| extra\_alert\_rules | More alert rules: a name to a Grafana alerting provisioning document (YAML), provisioned as rules-extra-<name>.json. Every rule needs labels area (host, pipeline or cost) and severity (warning or critical). To remove a rule, keep its uid under deleteRules in the same document. | `map(string)` | `{}` | no |
| extra\_dashboards | More dashboards to provision: "<Folder>/<name>.json" (the folder is created in Grafana) to the dashboard's JSON, which needs a uid and a title. | `map(string)` | `{}` | no |
| images | Container images to use instead of the module's digest-pinned defaults, by service name (see the README). | `map(string)` | `{}` | no |
| instance\_type | The instance type, arm64 (Graviton). A T type runs with standard CPU credits, so a burst never bills extra; watch its credit balance. | `string` | `"t9g.medium"` | no |
| prometheus\_retention | How long Prometheus keeps metrics, and the size it never grows past (the oldest data is dropped first). size\_gb is at least 1; keep it well under data\_volume\_gb. | <pre>object({<br/>    time    = optional(string, "365d")<br/>    size_gb = optional(number, 12)<br/>  })</pre> | `{}` | no |
| root\_volume\_gb | Size of the root volume: the OS, the images and a 2 GB swap file. | `number` | `12` | no |
| slack | Slack notifications: channels (name => the SSM SecureString parameter holding its incoming-webhook URL) and routes (area => channel; areas are host, pipeline and cost, and host is required, since the root policy uses it). null means no notifications: alerts show in Grafana only. Adding a channel is one webhook parameter and one line here. | <pre>object({<br/>    channels = map(string)<br/>    routes   = map(string)<br/>  })</pre> | `null` | no |
| snapshots | Daily snapshots of the data volume (Data Lifecycle Manager), at time\_utc, keeping the last `keep`. | <pre>object({<br/>    enabled  = optional(bool, false)<br/>    time_utc = optional(string, "03:00")<br/>    keep     = optional(number, 7)<br/>  })</pre> | `{}` | no |
| thresholds | Alert thresholds, which also set the dashboard's tile colours and dashed lines. Every attribute is optional and defaults to spec 6.8's numbers. Percentages are of the resource; cpu\_credits\_percent is of the instance type's maximum balance; container\_restarts counts restarts in 15 minutes; the *\_days are days. prometheus\_history\_days warns only while Prometheus is above prometheus\_size\_percent of its size cap, i.e. when the cap is costing history. | <pre>object({<br/>    cpu_percent               = optional(object({ warning = number, critical = number }), { warning = 60, critical = 85 })<br/>    cpu_credits_percent       = optional(object({ warning = number, critical = number }), { warning = 25, critical = 5 })<br/>    memory_percent            = optional(object({ warning = number, critical = number }), { warning = 70, critical = 90 })<br/>    swap_percent              = optional(object({ warning = number, critical = number }), { warning = 25, critical = 75 })<br/>    disk_percent              = optional(object({ warning = number, critical = number }), { warning = 70, critical = 90 })<br/>    disk_full_days            = optional(object({ warning = number, critical = number }), { warning = 7, critical = 2 })<br/>    inodes_percent            = optional(object({ warning = number, critical = number }), { warning = 70, critical = 90 })<br/>    prometheus_size_percent   = optional(object({ warning = number }), { warning = 85 })<br/>    prometheus_history_days   = optional(object({ warning = number }), { warning = 90 })<br/>    container_restarts        = optional(object({ warning = number, critical = number }), { warning = 1, critical = 3 })<br/>    tls_days                  = optional(object({ warning = number, critical = number }), { warning = 14, critical = 3 })<br/>    os_release_update_days    = optional(object({ warning = number }), { warning = 7 })<br/>    normalizer_hours          = optional(object({ warning = number, critical = number }), { warning = 3, critical = 12 })<br/>    aws_charge_days           = optional(object({ warning = number, critical = number }), { warning = 3, critical = 5 })<br/>    databricks_delivery_hours = optional(object({ warning = number, critical = number }), { warning = 36, critical = 60 })<br/>    cost_sync_hours           = optional(object({ warning = number, critical = number }), { warning = 2, critical = 6 })<br/>    anomaly_ratio             = optional(object({ warning = number, critical = number }), { warning = 2, critical = 4 })<br/>    untagged_daily_usd        = optional(object({ warning = number }), { warning = 0.5 })<br/>  })</pre> | `{}` | no |
| zone\_id | The Route 53 hosted zone of `domain`. The node may only upsert its own A record there, at every boot. | `string` | `null` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| config\_bucket | The bucket holding the node's config bundles. |
| data\_volume\_id | The data volume, kept when the instance is replaced. |
| grafana\_url | Where Grafana is: the domain over HTTPS, or a Session Manager port forward to localhost:3000. |
| instance\_id | The node's instance. |
| parameter\_prefix | The node's SSM parameters: config-bundle (what it should run), status and running-config (what it reports). |
| public\_ip | The node's public IPv4 address at creation; it changes on stop and start (the DNS record follows it). |
| role\_arn | The node's instance role ARN. |
| role\_name | The node's instance role. |
| security\_group\_id | The node's security group. |
<!-- END_TF_DOCS -->
