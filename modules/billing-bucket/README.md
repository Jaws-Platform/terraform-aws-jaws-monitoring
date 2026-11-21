# billing-bucket

Part of [`Jaws-Platform/jaws-monitoring/aws`](https://registry.terraform.io/modules/Jaws-Platform/jaws-monitoring/aws/latest) · [Registry](https://registry.terraform.io/modules/Jaws-Platform/jaws-monitoring/aws/latest/submodules/billing-bucket) · [Source](https://github.com/Jaws-Platform/terraform-aws-jaws-monitoring/tree/main/modules/billing-bucket)

The bucket every billing source delivers into. What a provider delivered is
kept forever, byte for byte; everything derived from it can be rebuilt.

```text
s3://<bucket_name>/
  raw/                                     # what each provider delivered; never deleted
    provider=aws/source=data-exports/      #   an AWS Data Export (aws-billing-export) writes here
    provider=<p>/source=<s>/…              #   any other source, in key=value folders
  normalized/                              # the normalizer's output; rebuildable from raw/
    schema=<schema>/provider=<p>/billing_period=YYYY-MM/data.parquet
```

What it creates: the bucket (versioned, SSE-S3, ACLs disabled, every Block
Public Access setting on), a lifecycle configuration and a bucket policy.
The bucket carries `Name` and `Component = "billing"`; every other tag comes
from the caller's provider `default_tags`.

## Protections

- **Nothing under `raw/` can be deleted.** With `protect_raw` on (the
  default), the policy denies `s3:DeleteObject` and `s3:DeleteObjectVersion`
  on `raw/*` to every principal. Versioning keeps every older version of an
  overwritten object, and no lifecycle rule touches `raw/`.
- **Only the normalized layer's old versions expire**, after
  `normalized_noncurrent_days`. The normalizer overwrites its objects in
  place, so the old versions are just an undo window.
- **TLS only.** Requests without TLS are denied.
- **No Object Lock.** Its compliance mode cannot be undone, even by the
  account's root. Lifting the delete deny takes an admin changing the policy
  on purpose.

## Order of operations

1. Create the bucket with the exporting account in
   `aws_export_source_account_ids`: the payer (management) account for an
   organization's whole bill. The policy then lets AWS Data Exports put
   objects for that account's exports only.
2. Create the export (`aws-billing-export`), with `prefix` set to this
   module's `aws_export_prefix` and, when the export lives in another
   account, `bucket_owner_account_id` set to this bucket's account.
3. Once the first deliveries have landed under the right prefixes, set
   `protect_raw = true` if you started with it off. From then on nothing
   under `raw/` can be deleted, and `terraform destroy` fails on this bucket
   by design.

AWS warns that editing the bucket policy or changing the bucket's owner after
an export exists can stop deliveries. This module only ever changes the
delete deny; the delivery statement stays as it was.

## Usage

```hcl
module "billing_bucket" {
  source  = "Jaws-Platform/jaws-monitoring/aws//modules/billing-bucket"
  version = "0.1.0" # x-release-please-version

  bucket_name                   = "acme-billing"
  aws_export_source_account_ids = ["111111111111"]
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

No modules.

## Resources

| Name | Type |
| ---- | ---- |
| [aws_s3_bucket.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket) | resource |
| [aws_s3_bucket_lifecycle_configuration.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_lifecycle_configuration) | resource |
| [aws_s3_bucket_ownership_controls.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_ownership_controls) | resource |
| [aws_s3_bucket_policy.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_policy) | resource |
| [aws_s3_bucket_public_access_block.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_public_access_block) | resource |
| [aws_s3_bucket_server_side_encryption_configuration.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_server_side_encryption_configuration) | resource |
| [aws_s3_bucket_versioning.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_versioning) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| bucket\_name | The bucket's name. Every billing source delivers under `raw/` and the<br/>normalizer writes under `normalized/` (see the README). Choose it before the<br/>first export is created: the export and the policies name it, and AWS stops<br/>delivering if the bucket changes. | `string` | n/a | yes |
| aws\_export\_source\_account\_ids | The AWS accounts whose Data Exports may deliver into this bucket, as 12-digit<br/>strings: the payer (management) account for organization-wide data, or any<br/>account that exports its own bill. AWS Data Exports may then put objects for<br/>those accounts' exports only. Empty: no export can deliver. | `list(string)` | `[]` | no |
| normalized\_noncurrent\_days | Days a replaced version of a `normalized/` object is kept before it expires.<br/>The normalized layer is rebuilt from `raw/` and overwritten in place, so its<br/>old versions are only an undo window. Raw data never expires. | `number` | `30` | no |
| protect\_raw | Deny deleting any object or object version under `raw/`, to every principal,<br/>so a delivered bill can never be lost. Switch it on once the first<br/>deliveries have been checked to land under the right prefixes: until then a<br/>misplaced first object can still be cleaned up. While it is on, the bucket<br/>cannot be destroyed (by design); an admin must change the policy first. | `bool` | `true` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| arn | The bucket's ARN, known at plan. |
| aws\_export\_prefix | The prefix to give an AWS Data Export (`aws-billing-export`'s `prefix`). AWS writes `<export-name>/data/` and `<export-name>/metadata/` below it. |
| name | The bucket's name. |
| normalized\_prefix | Where the normalizer writes, under `<normalized_prefix>/schema=<schema>/…`. Rebuildable from raw/. |
| raw\_prefix | Where every source delivers, under `<raw_prefix>/provider=<p>/source=<s>/`. Never deleted. |
<!-- END_TF_DOCS -->
