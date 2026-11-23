[![Jaws: one platform for every project on AWS](https://raw.githubusercontent.com/Jaws-Platform/jaws-branding/main/assets/banner/jaws-readme-banner.png)](https://github.com/Jaws-Platform)

# terraform-aws-jaws-monitoring

[![Terraform Registry](https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fregistry.terraform.io%2Fv1%2Fmodules%2FJaws-Platform%2Fjaws-monitoring%2Faws&query=%24.version&prefix=v&label=registry&logo=terraform&color=7B42BC)](https://registry.terraform.io/modules/Jaws-Platform/jaws-monitoring/aws/latest)
[![GitHub release](https://img.shields.io/github/v/release/Jaws-Platform/terraform-aws-jaws-monitoring?label=release)](https://github.com/Jaws-Platform/terraform-aws-jaws-monitoring/releases/latest)
[![CI](https://github.com/Jaws-Platform/terraform-aws-jaws-monitoring/actions/workflows/ci.yml/badge.svg?event=pull_request)](https://github.com/Jaws-Platform/terraform-aws-jaws-monitoring/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](https://github.com/Jaws-Platform/terraform-aws-jaws-monitoring/blob/main/LICENSE)

A self-hosted monitoring and cost platform on AWS, built to be cheap and to run
on one small instance. Its first job is cost: it collects billing data from
several providers (AWS, Databricks, and anything else that can deliver whole
billing periods), normalizes it to the FinOps
[FOCUS](https://focus.finops.org/) schema, and shows it next to the health of
the node itself.

It holds the cost pipeline (the bucket every source delivers into, the
organization-wide AWS export, and the normalizer that turns every delivery into
one table) and the monitoring node that shows it: Grafana with cost and host
dashboards, alert rules, Slack, an optional off-hours schedule, and a watchdog
outside the node. It is one of the
[Jaws](https://github.com/Jaws-Platform/jaws) module families, and has no
dependency on Jaws: names, accounts and prefixes are plain inputs.

## Submodules

| Submodule | What it is | Applied in |
|---|---|---|
| [`billing-bucket`](https://github.com/Jaws-Platform/terraform-aws-jaws-monitoring/tree/main/modules/billing-bucket) | The bucket every billing source delivers into. Raw deliveries are never deleted; the normalized layer is rebuildable from them | the account that runs the platform |
| [`aws-billing-export`](https://github.com/Jaws-Platform/terraform-aws-jaws-monitoring/tree/main/modules/aws-billing-export) | The FOCUS 1.2 daily AWS Data Export, in Parquet, delivered to that bucket, across accounts if needed | the account whose bill it exports: the payer, for every account of an organization |
| [`billing-normalizer`](https://github.com/Jaws-Platform/terraform-aws-jaws-monitoring/tree/main/modules/billing-normalizer) | An hourly Lambda that rebuilds each changed billing period of every source as FOCUS-aligned Parquet, and task-run records as an event table | the account that runs the platform |
| [`monitoring-node`](https://github.com/Jaws-Platform/terraform-aws-jaws-monitoring/tree/main/modules/monitoring-node) | One Graviton instance running Grafana (on Postgres), Prometheus and the exporters in Docker Compose, with a separate data volume, optional HTTPS, a host health dashboard, host and pipeline alert rules, Slack routing, a cost database loaded from the normalized billing data, and a config bundle that changes without replacing the instance | the account that runs the platform |

**The root module** wires the normalizer into the node, in the account that
runs the platform: the node reads what the normalizer writes, expects the
providers it is given, and joins task runs on its tags. Every submodule input
is a root input under the same name (the normalizer's `schedule_expression`,
`memory_size` and `log_retention_days` get a `normalizer_` prefix); one left
null takes the submodule's default. The bucket and the AWS export are applied
elsewhere, the bucket first.

```hcl
module "monitoring" {
  source  = "Jaws-Platform/jaws-monitoring/aws"
  version = "~> 0.8"

  name          = "acme-monitoring"
  bucket_name   = "acme-billing"
  vpc_id        = "vpc-0123"
  subnet_id     = "subnet-0123"
  ami_name      = "al2023-ami-2023.12.20261026.1-kernel-6.18-arm64"
  grafana_admin = { user_parameter = "/acme/grafana-user", password_parameter = "/acme/grafana-password" }

  aws        = { delivery_prefix = "raw/provider=aws/source=data-exports/acme-focus-daily" }
  databricks = {}
  budgets    = { total = 100 }
  schedule   = { timezone = "America/Denver", days = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"], on = "08:00", off = "24:00" }
}
```

[`examples/organization-billing`](https://github.com/Jaws-Platform/terraform-aws-jaws-monitoring/tree/main/examples/organization-billing)
shows the bucket and the export wired together across a payer and a platform
account.

## The bucket layout

Every source delivers whole billing periods under its own prefix, and the
newest delivery of a period wins. Adding a provider means a source that
delivers under `raw/provider=<p>/source=<s>/` and a mapper to the normalized
schema.

```text
s3://<bucket>/
  raw/                                     # what each provider delivered; never deleted
    provider=aws/source=data-exports/      #   AWS writes its own layout below this prefix:
                                           #   <export-name>/data/billing_period=YYYY-MM/<timestamp>-<execution-id>/…
                                           #   <export-name>/metadata/billing_period=YYYY-MM/Manifest.json
    provider=<p>/source=<s>/…              #   any other source, in key=value folders
  normalized/                              # the normalizer's output; rebuildable from raw/
    schema=focus-1.2/provider=<p>/billing_period=YYYY-MM/data.parquet
    schema=runs-1/event_month=YYYY-MM/data.parquet   # task-run events, joined to cost rows by tags
    _runs/<YYYYMMDDTHHMMSSZ>.json, _runs/latest.json # one record per normalizer run
```

The `key=value` folders are what Athena, DuckDB and Spark read as partitions,
so the whole history can be analyzed in bulk without reshaping.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| terraform | >= 1.11 |
| archive | ~> 2.7 |
| aws | ~> 6.0 |

## Providers

No providers.

## Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| node | ./modules/monitoring-node | n/a |
| normalizer | ./modules/billing-normalizer | n/a |

## Resources

No resources.

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| ami\_name | The exact name of the Amazon Linux 2023 arm64 image to run, e.g. `al2023-ami-2023.12.20261026.1-kernel-6.18-arm64`. Changing it replaces the instance; the data volume is reattached. | `string` | n/a | yes |
| bucket\_name | The billing bucket (the billing-bucket submodule, applied elsewhere): the normalizer reads its raw/ layer and writes normalized/, and the node reads normalized/. | `string` | n/a | yes |
| grafana\_admin | The SSM SecureString parameters (default aws/ssm key) holding Grafana's admin user name and password. Set them before the first apply. The node checks them every 5 minutes; a changed password is applied with Grafana's admin password reset. | <pre>object({<br/>    user_parameter     = string<br/>    password_parameter = string<br/>  })</pre> | n/a | yes |
| name | The name everything is named for: the node is <name>, the normalizer <name>-normalizer. | `string` | n/a | yes |
| subnet\_id | A public subnet for the node. The data volume is created in its availability zone, so moving the node to another zone means a new volume. | `string` | n/a | yes |
| vpc\_id | The VPC of the node's subnet. | `string` | n/a | yes |
| acme\_email | Optional contact address for Let's Encrypt. | `string` | `null` | no |
| anomaly\_floor\_usd | The node's cost.anomaly\_floor\_usd: a day must also be this many USD over its 14-day median to be an anomaly. | `number` | `null` | no |
| aws | The AWS Data Export source, or null for none. `delivery_prefix` is the export's<br/>`delivery_prefix` (`aws-billing-export`). Rows whose `PublisherName` is in<br/>`exclude_publishers` are dropped, for a provider also billed directly, such<br/>as Databricks bought through AWS Marketplace. | <pre>object({<br/>    delivery_prefix    = string<br/>    exclude_publishers = optional(list(string), [])<br/>  })</pre> | `null` | no |
| budgets | Monthly budgets in USD for the node's cost alerts: total, per project, and per account by id or name (the node's cost.budgets). | <pre>object({<br/>    total    = optional(number)<br/>    projects = optional(map(number), {})<br/>    accounts = optional(map(number), {})<br/>  })</pre> | `null` | no |
| data\_volume\_gb | Size of the data volume: Prometheus, Postgres, Grafana and Caddy's state, kept when the instance is replaced. | `number` | `null` | no |
| databricks | The Databricks system-table source, or null for none. `prefix` is where the<br/>daily job delivers (see the README for its layout). `account_name` names the<br/>billing account in the rows. `workspace_names` names workspaces the delivered<br/>workspace table does not; `workspace_projects` gives the `Project` of usage<br/>that carries none, by workspace ID or name. | <pre>object({<br/>    prefix             = optional(string, "raw/provider=databricks/source=system-tables")<br/>    account_name       = optional(string, "Databricks")<br/>    workspace_names    = optional(map(string), {})<br/>    workspace_projects = optional(map(string), {})<br/>  })</pre> | `null` | no |
| databricks\_workspace\_tag | The node's cost.databricks\_workspace\_tag: the tag whose value names a Databricks workspace on its AWS rows (the all-in cost). | `string` | `null` | no |
| domain | The name Grafana is served at over HTTPS (Caddy, Let's Encrypt). Null: no ingress at all; reach Grafana through a Session Manager port forward. | `string` | `null` | no |
| extra\_alert\_rules | More alert rules: a name to a Grafana alerting provisioning document (YAML), provisioned as rules-extra-<name>.json. Every rule needs labels area (host, pipeline or cost) and severity (warning or critical). To remove a rule, keep its uid under deleteRules in the same document. | `map(string)` | `null` | no |
| extra\_dashboards | More dashboards to provision: "<Folder>/<name>.json" (the folder is created in Grafana) to the dashboard's JSON, which needs a uid and a title. | `map(string)` | `null` | no |
| images | Container images to use instead of the module's digest-pinned defaults, by service name (see the README). | `map(string)` | `null` | no |
| instance\_type | The instance type, arm64 (Graviton). A T type runs with standard CPU credits, so a burst never bills extra; watch its credit balance. | `string` | `null` | no |
| normalized\_prefix | Where the normalized layer is written: `billing-bucket`'s `normalized_prefix`. No leading or trailing slash. | `string` | `null` | no |
| normalizer\_log\_retention\_days | Retention of the function's CloudWatch log group, in days. | `number` | `null` | no |
| normalizer\_memory\_size | The function's memory, in MB. A month of AWS line items takes roughly 6 KB per<br/>row at peak; raise it when a billing period reaches about 150,000 rows. | `number` | `null` | no |
| normalizer\_schedule\_expression | How often the normalizer runs, as an EventBridge Scheduler expression. A run with nothing new to read only writes its run record. | `string` | `null` | no |
| off\_hours\_page | With `schedule` and `domain`: at each scheduled stop, point `domain` at a CloudFront page that says Grafana is off and when it's back, instead of the stopped node's released address; the node points it back at boot. Needs the provider in us-east-1. Does nothing without both. | `bool` | `false` | no |
| pandas\_layer\_arn | The Lambda layer that provides pyarrow. Null uses the AWS SDK for pandas layer<br/>for Python 3.13 on arm64 in the function's region (awswrangler 3.18.0). | `string` | `null` | no |
| prometheus\_retention | How long Prometheus keeps metrics, and the size it never grows past (the oldest data is dropped first). size\_gb is at least 1; keep it well under data\_volume\_gb. | <pre>object({<br/>    time    = optional(string, "365d")<br/>    size_gb = optional(number, 12)<br/>  })</pre> | `null` | no |
| promoted\_tags | Tags promoted out of each row's tag map into their own `x_<tag>` columns, for<br/>grouping. A tag key is matched as written, as `user:<tag>` or as<br/>`user_<tag lowercased>`. Changing the list rebuilds every output. | `list(string)` | `null` | no |
| root\_volume\_gb | Size of the root volume: the OS, the images and a 2 GB swap file. | `number` | `null` | no |
| runs | Task-run event records (`runs-1`, see the README), or null for none. `prefixes`<br/>are where the records are written; `join_tags` are the resource tags whose<br/>values identify a run, in order, and join its events to its cost rows. | <pre>object({<br/>    prefixes  = list(string)<br/>    join_tags = list(string)<br/>  })</pre> | `null` | no |
| schedule | Off-hours: the node runs from on to off on the given days, in timezone (an IANA name), and is stopped otherwise. Whole hours, on before off, off may be 24:00 (midnight at the end of the day), at least 4 hours on, days from mon to sun. Avoid 01:00-03:00, when daylight saving changes. null runs the node all day. | <pre>object({<br/>    timezone = string<br/>    days     = list(string)<br/>    on       = string<br/>    off      = string<br/>  })</pre> | `null` | no |
| slack | Slack notifications: channels (name => the SSM SecureString parameter holding its incoming-webhook URL) and routes (area => channel; areas are host, pipeline and cost, and host is required, since the root policy uses it). null means no notifications: alerts show in Grafana only. Adding a channel is one webhook parameter and one line here. | <pre>object({<br/>    channels = map(string)<br/>    routes   = map(string)<br/>  })</pre> | `null` | no |
| snapshots | Daily snapshots of the data volume (AWS Backup), kept `keep` days. Without a schedule they run at time\_utc (HH:MM); with one, an hour after the stop in the schedule's time zone (03:00 when that falls in 01:00-02:59), so they capture disks shut down cleanly. | <pre>object({<br/>    enabled  = optional(bool, false)<br/>    time_utc = optional(string, "03:00")<br/>    keep     = optional(number, 7)<br/>  })</pre> | `null` | no |
| thresholds | Alert thresholds, which also set the dashboard's tile colours and dashed lines. Every attribute is optional and defaults to spec 6.8's numbers. Percentages are of the resource; cpu\_credits\_percent is of the instance type's maximum balance; container\_restarts counts restarts in 15 minutes; the *\_days are days. prometheus\_history\_days warns only while Prometheus is above prometheus\_size\_percent of its size cap, i.e. when the cap is costing history. | <pre>object({<br/>    cpu_percent               = optional(object({ warning = number, critical = number }), { warning = 60, critical = 85 })<br/>    cpu_credits_percent       = optional(object({ warning = number, critical = number }), { warning = 25, critical = 5 })<br/>    memory_percent            = optional(object({ warning = number, critical = number }), { warning = 70, critical = 90 })<br/>    swap_percent              = optional(object({ warning = number, critical = number }), { warning = 25, critical = 75 })<br/>    disk_percent              = optional(object({ warning = number, critical = number }), { warning = 70, critical = 90 })<br/>    disk_full_days            = optional(object({ warning = number, critical = number }), { warning = 7, critical = 2 })<br/>    inodes_percent            = optional(object({ warning = number, critical = number }), { warning = 70, critical = 90 })<br/>    prometheus_size_percent   = optional(object({ warning = number }), { warning = 85 })<br/>    prometheus_history_days   = optional(object({ warning = number }), { warning = 90 })<br/>    container_restarts        = optional(object({ warning = number, critical = number }), { warning = 1, critical = 3 })<br/>    tls_days                  = optional(object({ warning = number, critical = number }), { warning = 14, critical = 3 })<br/>    os_release_update_days    = optional(object({ warning = number }), { warning = 7 })<br/>    normalizer_hours          = optional(object({ warning = number, critical = number }), { warning = 3, critical = 12 })<br/>    aws_charge_days           = optional(object({ warning = number, critical = number }), { warning = 3, critical = 5 })<br/>    databricks_delivery_hours = optional(object({ warning = number, critical = number }), { warning = 36, critical = 60 })<br/>    cost_sync_hours           = optional(object({ warning = number, critical = number }), { warning = 2, critical = 6 })<br/>    anomaly_ratio             = optional(object({ warning = number, critical = number }), { warning = 2, critical = 4 })<br/>    untagged_daily_usd        = optional(object({ warning = number }), { warning = 0.5 })<br/>  })</pre> | `null` | no |
| zone\_id | The Route 53 hosted zone of `domain`. The node may only upsert its own A record there, at every boot. | `string` | `null` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| node | The monitoring node's outputs: its instance, address, role, config bucket, parameters, data volume, Grafana URL and watchdog. |
| normalizer | The billing normalizer's outputs: its function, role, log group, schedule, and where it writes. |
| off\_hours\_page\_domain\_name | The off-hours page's CloudFront domain name (null without the page). |
<!-- END_TF_DOCS -->
