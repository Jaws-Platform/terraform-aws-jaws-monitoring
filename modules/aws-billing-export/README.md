# aws-billing-export

Part of [`Jaws-Platform/jaws-monitoring/aws`](https://registry.terraform.io/modules/Jaws-Platform/jaws-monitoring/aws/latest) · [Registry](https://registry.terraform.io/modules/Jaws-Platform/jaws-monitoring/aws/latest/submodules/aws-billing-export) · [Source](https://github.com/Jaws-Platform/terraform-aws-jaws-monitoring/tree/main/modules/aws-billing-export)

An AWS Data Export of the bill in the FinOps
[FOCUS 1.2](https://focus.finops.org/) schema with AWS's extra columns
(`FOCUS_1_2_AWS`): daily line items, in Parquet, delivered to an S3 bucket
that may belong to another account.

**Create it in the account whose bill it exports.** In the payer
(management) account it covers every account of the organization; in a
member account it covers only that account's usage, and only since it
joined. Cost allocation tags appear in the `Tags` column once they are
activated in the payer account.

What it creates: one export, carrying `Name` and `Component = "billing"`;
every other tag comes from the caller's provider `default_tags`. It selects
all 60 columns of `FOCUS_1_2_AWS` explicitly.

## Where the files land

Every refresh is written to new files, so nothing already delivered is
overwritten:

```text
<prefix>/<name>/data/BILLING_PERIOD=YYYY-MM/<timestamp>-<execution-id>/<name>-00001.snappy.parquet
<prefix>/<name>/metadata/BILLING_PERIOD=YYYY-MM/Manifest.json
```

`Manifest.json` always describes the newest execution, and is written after
all of its data files. Read its `dataFiles` list rather than listing the
bucket. AWS refreshes the current month at least once a day, and may restate
the previous month for up to two weeks after it ends, so each billing
period's newest delivery is the one to use.

## Order of operations

1. Create the bucket, with this account allowed to deliver: `billing-bucket`
   with this account in `aws_export_source_account_ids`.
2. Create this export, with `prefix` set to the bucket's `aws_export_prefix`
   and, for a bucket in another account, `bucket_owner_account_id` set to
   that account. The first delivery arrives within about 24 hours.
3. For history from before the export existed, open a (free) AWS Support
   billing case after the first delivery, naming the account, the export and
   the months wanted. AWS backfills it into the same folders.

## Usage

```hcl
module "aws_billing_export" {
  source  = "Jaws-Platform/jaws-monitoring/aws//modules/aws-billing-export"
  version = "0.8.0" # x-release-please-version

  name                    = "acme-focus-daily"
  bucket_name             = "acme-billing"
  bucket_owner_account_id = "222222222222"
}
```

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| terraform | >= 1.11 |
| aws | >= 6.73, < 7.0 |

## Providers

| Name | Version |
| ---- | ------- |
| aws | >= 6.73, < 7.0 |

## Modules

No modules.

## Resources

| Name | Type |
| ---- | ---- |
| [aws_bcmdataexports_export.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/bcmdataexports_export) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| bucket\_name | The bucket AWS delivers into. Its policy must already let AWS Data Exports put<br/>objects for this account's exports (`billing-bucket` with this account in<br/>`aws_export_source_account_ids`), or creating the export fails. | `string` | n/a | yes |
| name | The export's name. AWS delivers under `<prefix>/<name>/`, so changing it<br/>starts a new delivery folder. | `string` | n/a | yes |
| bucket\_owner\_account\_id | The 12-digit account that owns `bucket_name`, when it is not the account this<br/>export is created in (cross-account delivery). Null for a bucket in the same<br/>account. | `string` | `null` | no |
| bucket\_region | The bucket's region. | `string` | `"us-east-1"` | no |
| description | The export's description, shown in the Billing console. | `string` | `"FOCUS 1.2 with AWS columns"` | no |
| prefix | The key prefix AWS delivers under, with no leading or trailing slash. The<br/>default is `billing-bucket`'s `aws_export_prefix`. | `string` | `"raw/provider=aws/source=data-exports"` | no |
| time\_granularity | The granularity of the line items: `HOURLY`, `DAILY` or `MONTHLY`. Daily is<br/>enough for cost dashboards and keeps the files small. | `string` | `"DAILY"` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| arn | The export's ARN. |
| delivery\_prefix | Where AWS delivers: `<delivery_prefix>/data/BILLING_PERIOD=YYYY-MM/<timestamp>-<execution-id>/` and `<delivery_prefix>/metadata/BILLING_PERIOD=YYYY-MM/Manifest.json`. |
| name | The export's name. |
<!-- END_TF_DOCS -->
