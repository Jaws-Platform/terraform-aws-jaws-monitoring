# billing-normalizer

Part of [`Jaws-Platform/jaws-monitoring/aws`](https://registry.terraform.io/modules/Jaws-Platform/jaws-monitoring/aws/latest) · [Registry](https://registry.terraform.io/modules/Jaws-Platform/jaws-monitoring/aws/latest/submodules/billing-normalizer) · [Source](https://github.com/Jaws-Platform/terraform-aws-jaws-monitoring/tree/main/modules/billing-normalizer)

A Lambda that turns every billing source's newest delivery in the billing
bucket into one FOCUS-aligned table, and task-run records into an event
table, every hour. Adding a provider means a source that delivers whole
billing periods under `raw/provider=<p>/source=<s>/` and one mapper here.

What it creates: the function (Python 3.13 on arm64, 15 minutes, 1 GB, on the
[AWS SDK for pandas](https://aws-sdk-pandas.readthedocs.io/en/stable/layers.html)
layer for pyarrow), its role, its log group, and an EventBridge Scheduler
schedule with its own role. Every resource carries `Name` and
`Component = "billing"`; every other tag comes from the caller's provider
`default_tags`.

## What it writes

```text
s3://<bucket_name>/<normalized_prefix>/
  schema=focus-1.2/provider=aws/billing_period=YYYY-MM/data.parquet
  schema=focus-1.2/provider=databricks/billing_period=YYYY-MM/data.parquet
  schema=runs-1/event_month=YYYY-MM/data.parquet
  _runs/<YYYYMMDDTHHMMSSZ>.json      one record per run
  _runs/latest.json                  the newest of them
```

The FOCUS table has the FOCUS 1.2 columns `ProviderName`, `BillingAccountId`,
`BillingAccountName`, `SubAccountId`, `SubAccountName`, `BillingPeriodStart`,
`ChargePeriodStart`, `ChargePeriodEnd`, `ChargeCategory`, `ChargeClass`,
`ServiceName`, `ServiceCategory`, `SkuId`, `RegionId`, `ResourceId`,
`ConsumedQuantity`, `ConsumedUnit`, `ListCost`, `BilledCost`, `EffectiveCost`,
`BillingCurrency` and `Tags`, then one `x_<tag>` column per promoted tag,
`x_Serverless` and `x_Source`. It is FOCUS-aligned, not certified.

Each `data.parquet` has a twin beside it, `data.csv.gz`, with the same rows,
columns and metadata. The monitoring node loads the twin with Postgres's
`COPY` and has no Parquet reader. Its format, `csv-twin-1`:

- gzip, UTF-8, a header row, columns in the Parquet's order;
- every value quoted; a NULL is an unquoted empty field, so `""` stays an
  empty string;
- timestamps in ISO 8601 with their offset, booleans `true` or `false`, maps
  as JSON objects with sorted keys.

The twin is written before its Parquet, so an output whose Parquet carries the
current signature always has its twin.

## When it rebuilds

Every source delivers whole billing periods, and the newest delivery of a
period wins. Each output carries the S3 metadata `source-signature`: a hash of
the mapper version, the provider's configuration, the promoted tags and the
identities of its source objects. A run rebuilds only the outputs whose
signature changed, so a run with nothing new writes only its run record.
Corrections and restatements arrive as new deliveries and simply replace the
period. Changing the configuration or upgrading to a release with a new
mapper version rebuilds everything from `raw/`.

Each output is built on its own: one that fails is reported and every other
output is still written, so a bad old period never freezes the current one.
Task runs go first, as the smallest and most time-critical table, and only the
FOCUS columns are read from an AWS delivery. The run record is always written;
the invocation then fails, so the function's `Errors` metric shows it. An
output's warnings (unpriced Databricks usage, skipped run records) are kept
on it and reported by every run for as long as the output stands, not just
by the run that built it.

```json
{"schema": "normalizer-run-1", "started_at": "…Z", "ended_at": "…Z", "status": "ok",
 "outputs": [{"key": "…", "provider": "aws", "period": "2026-11", "rebuilt": true, "rows": 1234, "billed_cost": 12.34}],
 "warnings": ["databricks 2026-11: 3 rows have no list price"], "errors": []}
```

## What it reads

**AWS** (`aws`): an AWS Data Export of `FOCUS_1_2_AWS` (`aws-billing-export`).
For each `metadata/BILLING_PERIOD=YYYY-MM/` folder under `delivery_prefix`, the
newest `…Manifest.json` names the data files of the newest execution. Rows
whose `PublisherName` is in `exclude_publishers` are dropped.

**Databricks** (`databricks`): a daily job's snapshots of the billing system
tables, the newest `run=` of each winning:

```text
<prefix>/table=usage/billing_period=YYYY-MM/run=<YYYYMMDDTHHMMSSZ>/part-*.parquet   system.billing.usage
<prefix>/table=list_prices/run=<YYYYMMDDTHHMMSSZ>/part-*.parquet                    system.billing.list_prices
<prefix>/table=workspaces/run=<YYYYMMDDTHHMMSSZ>/part-*.parquet  (optional)         workspace_id, workspace_name
```

Cost is `usage_quantity` × the list price, `pricing.effective_list.default`
(else `pricing.default`), matched on `sku_name` and `cloud` where
`price_start_time <= usage_end_time < price_end_time`. For a pay-as-you-go
account the list price is the billed price; usage with no matching price is
kept at zero cost and reported as a warning. `RETRACTION` and `RESTATEMENT`
rows become `ChargeClass = "Correction"`. A row without a `Project` tag takes
it from `workspace_projects` (by workspace ID or name). `RegionId` is null:
no system table gives a workspace's region.

**Task runs** (`runs`): one JSON object per event, at
`<prefix>/…/date=YYYY-MM-DD/<anything>.json`, grouped by that month. The run's
`join_tags` values are the tags on its resources, so the event table joins to
the cost rows. A record that is invalid in any way (not an object, a missing
field, a value out of range) is skipped and reported as a warning; it never
blocks the other records.

```json
{"schema": "runs-1", "event": "started | finished | swept", "at": "2026-11-24T21:10:03Z",
 "tags": {"RunId": "123456-1", "TaskId": "net-v12"}, "project": "braveheart-trainer",
 "campaign": "net-v12", "kind": "train",
 "instance": {"type": "g6e.xlarge", "accelerators": 1, "market": "spot", "zone": "use1-az4", "id": "i-0abc"},
 "prices": {"hourly_usd": 1.07, "on_demand_hourly_usd": 1.861, "worst_case_usd": 11.17, "ceiling_usd": 50, "max_hours": 6},
 "outcome": "passed", "exit_code": 0, "interrupted_at": null, "reason": null,
 "links": {"run": "https://github.com/…"}, "attributes": {"profile": "gpu"}}
```

Only `schema`, `event`, `at`, `tags` (with every join tag) and `project` are
required; `finished` sets `outcome`, `exit_code` and `interrupted_at`, `swept`
sets `reason`.

**Tags.** AWS does not document how FOCUS writes the keys of user-defined
cost allocation tags, so a promoted tag `Project` is matched as `Project`,
`user:Project` or `user_project`, in that order.

## Usage

```hcl
module "billing_normalizer" {
  source  = "Jaws-Platform/jaws-monitoring/aws//modules/billing-normalizer"
  version = "0.4.0" # x-release-please-version

  name        = "acme-billing-normalizer"
  bucket_name = "acme-billing"

  aws = {
    delivery_prefix = "raw/provider=aws/source=data-exports/acme-focus-daily"
  }
  databricks = {}
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

No modules.

## Resources

| Name | Type |
| ---- | ---- |
| [aws_cloudwatch_log_group.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group) | resource |
| [aws_iam_role.scheduler](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.scheduler](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_lambda_function.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_function) | resource |
| [aws_scheduler_schedule.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/scheduler_schedule) | resource |
| [archive_file.code](https://registry.terraform.io/providers/hashicorp/archive/latest/docs/data-sources/file) | data source |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| bucket\_name | The billing bucket (`billing-bucket`) the sources deliver into and the normalized layer is written to. | `string` | n/a | yes |
| name | The function's name; also names its role, log group, scheduler role and schedule. | `string` | n/a | yes |
| aws | The AWS Data Export source, or null for none. `delivery_prefix` is the export's<br/>`delivery_prefix` (`aws-billing-export`). Rows whose `PublisherName` is in<br/>`exclude_publishers` are dropped, for a provider also billed directly, such<br/>as Databricks bought through AWS Marketplace. | <pre>object({<br/>    delivery_prefix    = string<br/>    exclude_publishers = optional(list(string), [])<br/>  })</pre> | `null` | no |
| databricks | The Databricks system-table source, or null for none. `prefix` is where the<br/>daily job delivers (see the README for its layout). `account_name` names the<br/>billing account in the rows. `workspace_names` names workspaces the delivered<br/>workspace table does not; `workspace_projects` gives the `Project` of usage<br/>that carries none, by workspace ID or name. | <pre>object({<br/>    prefix             = optional(string, "raw/provider=databricks/source=system-tables")<br/>    account_name       = optional(string, "Databricks")<br/>    workspace_names    = optional(map(string), {})<br/>    workspace_projects = optional(map(string), {})<br/>  })</pre> | `null` | no |
| log\_retention\_days | Retention of the function's CloudWatch log group, in days. | `number` | `30` | no |
| memory\_size | The function's memory, in MB. A month of AWS line items takes roughly 6 KB per<br/>row at peak; raise it when a billing period reaches about 150,000 rows. | `number` | `1024` | no |
| normalized\_prefix | Where the normalized layer is written: `billing-bucket`'s `normalized_prefix`. No leading or trailing slash. | `string` | `"normalized"` | no |
| pandas\_layer\_arn | The Lambda layer that provides pyarrow. Null uses the AWS SDK for pandas layer<br/>for Python 3.13 on arm64 in the function's region (awswrangler 3.18.0). | `string` | `null` | no |
| promoted\_tags | Tags promoted out of each row's tag map into their own `x_<tag>` columns, for<br/>grouping. A tag key is matched as written, as `user:<tag>` or as<br/>`user_<tag lowercased>`. Changing the list rebuilds every output. | `list(string)` | <pre>[<br/>  "Project",<br/>  "Component",<br/>  "Environment"<br/>]</pre> | no |
| runs | Task-run event records (`runs-1`, see the README), or null for none. `prefixes`<br/>are where the records are written; `join_tags` are the resource tags whose<br/>values identify a run, in order, and join its events to its cost rows. | <pre>object({<br/>    prefixes  = list(string)<br/>    join_tags = list(string)<br/>  })</pre> | `null` | no |
| schedule\_expression | How often the normalizer runs, as an EventBridge Scheduler expression. A run with nothing new to read only writes its run record. | `string` | `"rate(1 hour)"` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| function\_arn | The normalizer function's ARN, known at plan. |
| function\_name | The normalizer function's name, to invoke it by hand. |
| log\_group\_name | The function's CloudWatch log group. |
| outputs | Where it writes: the FOCUS table, the runs event table and the run records, under the bucket. |
| role\_arn | The function's role ARN. |
| role\_name | The function's role. |
| schedule\_name | The EventBridge Scheduler schedule that runs it. |
<!-- END_TF_DOCS -->
