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
  kept when the instance is replaced, with optional daily snapshots (AWS
  Backup, vault `<name>-snapshots`);
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

### The watchdog

With `slack`, the node is watched from outside, so a dead node still gets
reported:

- **Two CloudWatch alarms:** a failed system status check makes EC2 recover
  the instance onto other hardware; a failed instance status check reboots
  it. A stopped instance sends no data, so a scheduled stop is silent.
- **The watchdog Lambda** (`<name>-watchdog`) runs every 5 minutes, and at
  once when an alarm changes, and posts to `host`'s channel:

  | Problem | Severity | When |
  |---|---|---|
  | Monitoring node not running | critical | it should be running, and isn't, on two checks in a row; never in the 15 minutes after a scheduled start |
  | Monitoring node running off-hours | warning | it is running in its off window (a stop that failed is quietly costing money); never in the 15 minutes after a scheduled stop |
  | Grafana not answering | critical | with a `domain`, `https://<domain>/api/health` failed twice in a row |
  | EC2 system / instance status check failed | critical | while its alarm is in ALARM |

  Each posts once, again every 4 hours while it lasts, and once when it
  resolves. Its state is the parameter `/<name>/node/watchdog-state`.

### Off-hours

`schedule` stops the node outside its hours, and starts it again:

```hcl
schedule = {
  timezone = "America/Denver"
  days     = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]
  on       = "08:00"
  off      = "24:00"   # midnight at the end of the day
}
```

- **Allowed shapes:** whole hours; `on` before `off` on the same day (no
  overnight windows); `off` may be `24:00`; at least 4 hours on; one or more
  unique days. Avoid 01:00 to 03:00, when daylight saving changes: a start
  or stop there can be skipped or doubled once a year.
- **How:** two EventBridge Scheduler schedules call `StartInstances` and
  `StopInstances` in the schedule's time zone. A stop is a normal shutdown.
- **With Slack,** notifications are muted for the first 15 minutes after each
  scheduled start, while targets come up and cost-sync catches up. Every area
  gets its own route then, so nothing falls through to the unmuted root.
- **Off-hours page** (`off_hours_page = true`, needs `domain` and the provider
  in us-east-1): the stopped node's address is released, so without this the
  name hangs overnight. A CloudFront function (free tier, no bucket or Lambda)
  answers `domain` with a 503 page saying when Grafana is back, and a third
  schedule points `domain` at it at each stop; the node points it back at boot.
  If the zone has CAA records, they must allow Amazon (`amazon.com`).
  The identity running Terraform needs ACM in us-east-1, CloudFront
  distribution and function management, and a Route 53 change for the
  certificate's validation CNAME. The first apply waits several minutes for
  the certificate and the CloudFront deployment. Turn the page off during
  on-hours: turning it off while the name is an alias leaves the name on a
  deleted distribution until the node's next boot. Turning it off also deletes
  the certificate's validation CNAME, which another ACM certificate for the
  same name in the account would share.
- **Snapshots** run an hour after the stop, in the schedule's time zone (03:00
  when that falls between 01:00 and 02:59), so they capture disks that were
  shut down cleanly. Without a schedule they run at `snapshots.time_utc`.
- **The vault keeps its snapshots:** turning `snapshots` off, or destroying the
  node, needs its recovery points deleted first (AWS Backup → Vaults →
  `<name>-snapshots`), so a stray destroy never deletes the backups.
- **Patching** (the newer-release check) already runs at boot and every 6
  hours, so it needs nothing from the schedule.
- Jaws's 08:00 to midnight saves a third of the instance and IPv4 costs; the
  disks are billed either way.

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
  # databricks_workspace_tag = "Workspace"     # names a workspace on its AWS rows (the all-in)
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
| `cost.task_run_costs` | each run's billed cost: the cost rows that carry its join tags, in any key form |
| `cost.loads`, `cost.normalizer_runs` | what was loaded, and the normalizer runs seen |
| `cost.daily` | spend per UTC day, provider, account, project (`(untagged)` without one), environment, component, service and charge category, with whether the day is `complete` and whether it is a `long_period` charge |
| `cost.month_to_date` | per scope (`total`, each project, each account): month to date, the forecast, the budget, and both as a share of it |
| `cost.anomalies` | each of the last three days' spend per total, project and service against the median of the 14 complete days before it |
| `cost.untagged`, `cost.untagged_new` | untagged spend (tax and credits aside), and each account and service's first untagged day and spend since; `is_new` when that day is the newest or the day before |
| `cost.budgets`, `cost.as_of` | the budgets from the `cost` input (rewritten every run), and the newest complete day |
| `cost.runs` | one row per task run, from its record or, without one, its tagged cost rows: project, campaign, workflow, profile, instance, hours, outcome, cost (billed, or an `estimated` hours × hourly price), ceiling share, GPU-hours, links |
| `cost.campaigns` | per campaign and project: runs, outcomes, hours, cost, savings against on demand, cost per passed run |
| `cost.databricks_daily`, `cost.databricks_all_in` | Databricks per day by workspace, product, SKU and serverless, with DBUs, at list price; and each workspace's all-in cost |
| `cost.tag(tags, key)` | a tag's value, whichever key form FOCUS wrote: `Key`, `user:Key` or `user_key` |

**Days and the forecast.**

- Days are UTC calendar days, because AWS bills in UTC. A day is complete 48 hours after it ends; until then its charges are still arriving.
- The month-end forecast is the month's complete days, plus, for every day not complete yet, what it has so far or the last 7 complete days' average, whichever is more. It is never below what's already spent.
- A charge for more than a day (a monthly fee, a support plan, often tax) is dated to its period's start. It counts as spent and in the forecast, but not as a day's spend: the average, the anomalies and new untagged spend leave it out, so the 1st of a month isn't an anomaly.

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
| Daily spend anomaly (the total and each project): each of the last three days with data against the median of its 14 complete days before, and over `anomaly_floor_usd` above it. One alert per day judged, so a provider that reports a day late (Databricks) is judged when its day lands | 2× | 4× | `thresholds.anomaly_ratio`, `cost.anomaly_floor_usd` |
| New untagged spend: an account and service with none in the 14 days before, over the threshold since it started (on the newest day or the day before, so a charge that starts late in a day still counts its next whole day) | over $0.50 | | `thresholds.untagged_daily_usd` |

Each cost alert posts once when it fires, then weekly while it lasts, to the
`cost` route's channel (or `host`'s): a breached budget stays breached all
month. A planned expensive run will trip the anomaly alert: silence it first
(see Silences). A project that spent on fewer than half of its 14 days has a
median of 0, so only the total can alert on its spending.

**Cost · Overview** (folder `Cost`) shows the last 90 days, filtered by
provider, account, project and environment. Tiles across the top: month to
date, forecast and spend against the total budget, yesterday, the month-on-
month change, untagged spend and the newest complete day. Below them, the
trend, where the money goes, the budgets, the biggest movers and the
untagged spend.

Every multi-value filter's "All" is `'__all'`, so a filter with no values
yet (a new node) never breaks a panel.

**Cost · Project** shows one project over the last 90 days: its month to
date, budget and forecast, each month's running spend against the budget,
and spend by component, service and environment, daily and month to date.

**Cost · Databricks** (when `databricks` is a provider) shows spend and DBUs
by product, workspace and SKU, serverless against classic, at list price,
which is what's billed when paying as you go. Its **all-in** panels add the
AWS rows whose `databricks_workspace_tag` tag (`Workspace`) names the
workspace: classic clusters' EC2 and EBS, and the workspace's other tagged
AWS resources. They count only once that tag is an active cost allocation
tag and workspace names are exported; until then the AWS part is 0.

**Cost · Tasks** shows the last 30 days of task runs, filtered by project,
campaign, workflow, profile, outcome and market: spend tiles, campaigns (a
click filters to one), one row per run, spend by workflow, and efficiency.

- **A run's record** gives its metadata. The table reads `links.run`,
  `links.pr` and `links.commit` (Run, PR and Commit open them), and
  `attributes.profile` and `attributes.lifecycle`.
- **A run with no record** (before records, or one that failed to write) is
  built from its tagged cost rows: `RunId`, `TaskId`, `Workflow`, `Profile`,
  `Lifecycle`, `Campaign`. Its hours are its instance hours (`Hrs` usage).
- **Cost** is billed, or marked `~` as an estimate (hours × the hourly price
  paid) until the run's last day is complete.
- **Tag keys** are read in any of FOCUS's three forms (`RunId`,
  `user:RunId`, `user_runid`), since AWS doesn't document which it writes.

## Recovery

| Event | What happens | What's lost |
|---|---|---|
| Stop and start (or a schedule) | The disks persist; the stack comes back, cost-sync catches up, and DNS follows the new address | Metrics for the time it was off |
| Reboot or EC2 recovery (the status-check alarms) | Same disks, same instance | Minutes of metrics |
| Instance replaced | The new instance reattaches the data volume and carries on | Minutes of metrics |
| Data volume lost | Dashboards and alerts are reprovisioned from the bundle, and cost-sync rebuilds the cost database from `normalized/`; Grafana users other than the admin must be added again | Prometheus history since the last snapshot |

## Usage

```hcl
module "monitoring_node" {
  source  = "Jaws-Platform/jaws-monitoring/aws//modules/monitoring-node"
  version = "0.8.2" # x-release-please-version

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
| archive | ~> 2.7 |
| aws | ~> 6.0 |

## Providers

| Name | Version |
| ---- | ------- |
| archive | ~> 2.7 |
| aws | ~> 6.0 |

## Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| grafana | ./grafana | n/a |

## Resources

| Name | Type |
| ---- | ---- |
| [aws_acm_certificate.off_hours_page](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/acm_certificate) | resource |
| [aws_acm_certificate_validation.off_hours_page](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/acm_certificate_validation) | resource |
| [aws_backup_plan.snapshots](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/backup_plan) | resource |
| [aws_backup_selection.snapshots](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/backup_selection) | resource |
| [aws_backup_vault.snapshots](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/backup_vault) | resource |
| [aws_cloudfront_distribution.off_hours_page](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudfront_distribution) | resource |
| [aws_cloudfront_function.off_hours_page](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudfront_function) | resource |
| [aws_cloudwatch_log_group.watchdog](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group) | resource |
| [aws_cloudwatch_metric_alarm.instance_status](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_metric_alarm) | resource |
| [aws_cloudwatch_metric_alarm.system_status](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_metric_alarm) | resource |
| [aws_ebs_volume.data](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ebs_volume) | resource |
| [aws_iam_instance_profile.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_instance_profile) | resource |
| [aws_iam_role.schedule](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.snapshots](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.watchdog](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.watchdog_schedule](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.off_hours_page](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy.schedule](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy.watchdog](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy.watchdog_schedule](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy_attachment.snapshots](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_instance.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/instance) | resource |
| [aws_lambda_function.watchdog](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_function) | resource |
| [aws_lambda_permission.watchdog_sns](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_permission) | resource |
| [aws_route53_record.off_hours_page_validation](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route53_record) | resource |
| [aws_route53_record.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route53_record) | resource |
| [aws_s3_bucket.config](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket) | resource |
| [aws_s3_bucket_lifecycle_configuration.config](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_lifecycle_configuration) | resource |
| [aws_s3_bucket_ownership_controls.config](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_ownership_controls) | resource |
| [aws_s3_bucket_public_access_block.config](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_public_access_block) | resource |
| [aws_s3_bucket_server_side_encryption_configuration.config](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_server_side_encryption_configuration) | resource |
| [aws_s3_bucket_versioning.config](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_versioning) | resource |
| [aws_s3_object.bundle](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_object) | resource |
| [aws_scheduler_schedule.off_hours_page](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/scheduler_schedule) | resource |
| [aws_scheduler_schedule.start](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/scheduler_schedule) | resource |
| [aws_scheduler_schedule.stop](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/scheduler_schedule) | resource |
| [aws_scheduler_schedule.watchdog](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/scheduler_schedule) | resource |
| [aws_security_group.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
| [aws_sns_topic.watchdog](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sns_topic) | resource |
| [aws_sns_topic_subscription.watchdog](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sns_topic_subscription) | resource |
| [aws_ssm_parameter.config_bundle](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ssm_parameter) | resource |
| [aws_ssm_parameter.running_config](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ssm_parameter) | resource |
| [aws_ssm_parameter.status](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ssm_parameter) | resource |
| [aws_volume_attachment.data](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/volume_attachment) | resource |
| [aws_vpc_security_group_egress_rule.all](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_egress_rule) | resource |
| [aws_vpc_security_group_ingress_rule.web](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_ingress_rule) | resource |
| [archive_file.watchdog](https://registry.terraform.io/providers/hashicorp/archive/latest/docs/data-sources/file) | data source |
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
| cost | The cost data, read from the billing bucket's normalized/ layer (the billing-normalizer's CSV twins): bucket, the normalizer's prefix, the providers expected there (for the staleness alerts), the tags a task run's cost rows are joined on, monthly budgets in USD (total, per project, per account by id or name), the anomaly floor (the day's spend must also be this many USD over its 14-day median), and the tag whose value names a Databricks workspace on its AWS resources (the all-in cost; it must be an active cost allocation tag). null for a host-only node. With it, cost-sync keeps the cost database on the node and Grafana reads it. | <pre>object({<br/>    bucket            = string<br/>    normalized_prefix = optional(string, "normalized")<br/>    providers         = optional(set(string), ["aws", "databricks"])<br/>    run_join_tags     = optional(list(string), ["RunId", "TaskId"])<br/>    budgets = optional(object({<br/>      total    = optional(number)<br/>      projects = optional(map(number), {})<br/>      accounts = optional(map(number), {})<br/>    }), {})<br/>    anomaly_floor_usd        = optional(number, 2)<br/>    databricks_workspace_tag = optional(string, "Workspace")<br/>  })</pre> | `null` | no |
| data\_volume\_gb | Size of the data volume: Prometheus, Postgres, Grafana and Caddy's state, kept when the instance is replaced. | `number` | `30` | no |
| domain | The name Grafana is served at over HTTPS (Caddy, Let's Encrypt). Null: no ingress at all; reach Grafana through a Session Manager port forward. | `string` | `null` | no |
| extra\_alert\_rules | More alert rules: a name to a Grafana alerting provisioning document (YAML), provisioned as rules-extra-<name>.json. Every rule needs labels area (host, pipeline or cost) and severity (warning or critical). To remove a rule, keep its uid under deleteRules in the same document. | `map(string)` | `{}` | no |
| extra\_dashboards | More dashboards to provision: "<Folder>/<name>.json" (the folder is created in Grafana) to the dashboard's JSON, which needs a uid and a title. | `map(string)` | `{}` | no |
| images | Container images to use instead of the module's digest-pinned defaults, by service name (see the README). | `map(string)` | `{}` | no |
| instance\_type | The instance type, arm64 (Graviton). A T type runs with standard CPU credits, so a burst never bills extra; watch its credit balance. | `string` | `"t9g.medium"` | no |
| off\_hours\_page | With `schedule` and `domain`: at each scheduled stop, point `domain` at a CloudFront page that says Grafana is off and when it's back, instead of the stopped node's released address; the node points it back at boot. Needs the provider in us-east-1. Does nothing without both. | `bool` | `false` | no |
| prometheus\_retention | How long Prometheus keeps metrics, and the size it never grows past (the oldest data is dropped first). size\_gb is at least 1; keep it well under data\_volume\_gb. | <pre>object({<br/>    time    = optional(string, "365d")<br/>    size_gb = optional(number, 12)<br/>  })</pre> | `{}` | no |
| root\_volume\_gb | Size of the root volume: the OS, the images and a 2 GB swap file. | `number` | `12` | no |
| schedule | Off-hours: the node runs from on to off on the given days, in timezone (an IANA name), and is stopped otherwise. Whole hours, on before off, off may be 24:00 (midnight at the end of the day), at least 4 hours on, days from mon to sun. Avoid 01:00-03:00, when daylight saving changes. null runs the node all day. | <pre>object({<br/>    timezone = string<br/>    days     = list(string)<br/>    on       = string<br/>    off      = string<br/>  })</pre> | `null` | no |
| slack | Slack notifications: channels (name => the SSM SecureString parameter holding its incoming-webhook URL) and routes (area => channel; areas are host, pipeline and cost, and host is required, since the root policy uses it). null means no notifications: alerts show in Grafana only. Adding a channel is one webhook parameter and one line here. | <pre>object({<br/>    channels = map(string)<br/>    routes   = map(string)<br/>  })</pre> | `null` | no |
| snapshots | Daily snapshots of the data volume (AWS Backup), kept `keep` days. Without a schedule they run at time\_utc (HH:MM); with one, an hour after the stop in the schedule's time zone (03:00 when that falls in 01:00-02:59), so they capture disks shut down cleanly. | <pre>object({<br/>    enabled  = optional(bool, false)<br/>    time_utc = optional(string, "03:00")<br/>    keep     = optional(number, 7)<br/>  })</pre> | `{}` | no |
| thresholds | Alert thresholds, which also set the dashboard's tile colours and dashed lines. Every attribute is optional and defaults to spec 6.8's numbers. Percentages are of the resource; cpu\_credits\_percent is of the instance type's maximum balance; container\_restarts counts restarts in 15 minutes; the *\_days are days. prometheus\_history\_days warns only while Prometheus is above prometheus\_size\_percent of its size cap, i.e. when the cap is costing history. | <pre>object({<br/>    cpu_percent               = optional(object({ warning = number, critical = number }), { warning = 60, critical = 85 })<br/>    cpu_credits_percent       = optional(object({ warning = number, critical = number }), { warning = 25, critical = 5 })<br/>    memory_percent            = optional(object({ warning = number, critical = number }), { warning = 70, critical = 90 })<br/>    swap_percent              = optional(object({ warning = number, critical = number }), { warning = 25, critical = 75 })<br/>    disk_percent              = optional(object({ warning = number, critical = number }), { warning = 70, critical = 90 })<br/>    disk_full_days            = optional(object({ warning = number, critical = number }), { warning = 7, critical = 2 })<br/>    inodes_percent            = optional(object({ warning = number, critical = number }), { warning = 70, critical = 90 })<br/>    prometheus_size_percent   = optional(object({ warning = number }), { warning = 85 })<br/>    prometheus_history_days   = optional(object({ warning = number }), { warning = 90 })<br/>    container_restarts        = optional(object({ warning = number, critical = number }), { warning = 1, critical = 3 })<br/>    tls_days                  = optional(object({ warning = number, critical = number }), { warning = 14, critical = 3 })<br/>    os_release_update_days    = optional(object({ warning = number }), { warning = 7 })<br/>    normalizer_hours          = optional(object({ warning = number, critical = number }), { warning = 3, critical = 12 })<br/>    aws_charge_days           = optional(object({ warning = number, critical = number }), { warning = 3, critical = 5 })<br/>    databricks_delivery_hours = optional(object({ warning = number, critical = number }), { warning = 36, critical = 60 })<br/>    cost_sync_hours           = optional(object({ warning = number, critical = number }), { warning = 2, critical = 6 })<br/>    anomaly_ratio             = optional(object({ warning = number, critical = number }), { warning = 2, critical = 4 })<br/>    untagged_daily_usd        = optional(object({ warning = number }), { warning = 0.5 })<br/>  })</pre> | `{}` | no |
| zone\_id | The Route 53 hosted zone of `domain`. The node may only upsert its own A record there, at every boot. | `string` | `null` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| config\_bucket | The bucket holding the node's config bundles. |
| data\_volume\_id | The data volume, kept when the instance is replaced. |
| grafana\_url | Where Grafana is: the domain over HTTPS, or a Session Manager port forward to localhost:3000. |
| instance\_id | The node's instance. |
| off\_hours\_page\_domain\_name | The off-hours page's CloudFront domain name (null without the page). |
| parameter\_prefix | The node's SSM parameters: config-bundle (what it should run), status and running-config (what it reports). |
| public\_ip | The node's public IPv4 address at creation; it changes on stop and start (the DNS record follows it). |
| role\_arn | The node's instance role ARN. |
| role\_name | The node's instance role. |
| security\_group\_id | The node's security group. |
| watchdog\_function\_name | The watchdog Lambda's name, to invoke it by hand (null without Slack). |
<!-- END_TF_DOCS -->
