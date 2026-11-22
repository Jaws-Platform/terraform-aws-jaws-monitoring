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

- **No delete call can remove anything under `raw/`.** With `protect_raw` on
  (the default), the policy denies `s3:DeleteObject` and
  `s3:DeleteObjectVersion` on `raw/*` to every principal. Versioning keeps
  every older version of an overwritten object, and no lifecycle rule
  touches `raw/`.
- **The bucket refuses destroy and replacement.** It carries
  `lifecycle { prevent_destroy = true }`, so a plan that would destroy or
  replace it (a new `bucket_name`, or removing the module) fails before
  anything is changed. Without it, Terraform would remove the policy,
  versioning and public access block first, and only then fail on the
  non-empty bucket.
- **Only the normalized layer's old versions expire**, after
  `normalized_noncurrent_days`. The normalizer overwrites its objects in
  place, so the old versions are just an undo window.
- **TLS only.** Requests without TLS are denied.
- **No Object Lock.** Its compliance mode cannot be undone, even by the
  account's root. What is left is deliberate admin action outside this
  module: changing the bucket policy, adding a lifecycle rule (expirations
  are not subject to the policy's deny), or suspending versioning.

## Order of operations

1. Create the bucket with the exporting account in
   `aws_export_source_account_ids`: the payer (management) account for an
   organization's whole bill. The policy then lets AWS Data Exports put
   objects for that account's exports only.
2. Create the export (`aws-billing-export`), with `prefix` set to this
   module's `aws_export_prefix` and, when the export lives in another
   account, `bucket_owner_account_id` set to this bucket's account.
3. Once the first deliveries have landed under the right prefixes, set
   `protect_raw = true` if you started with it off. From then on no delete
   call can remove anything under `raw/`.

AWS warns that editing the bucket policy or changing the bucket's owner after
an export exists can stop deliveries. Toggling `protect_raw` leaves the
delivery statement as it was; changing `aws_export_source_account_ids`
rewrites it, so check the next delivery after such a change.

To stop managing the bucket without deleting it, replace the module call
with a `removed` block; the bucket and its data stay in the account:

```hcl
removed {
  from = module.billing_bucket

  lifecycle {
    destroy = false
  }
}
```

## Usage

```hcl
module "billing_bucket" {
  source  = "Jaws-Platform/jaws-monitoring/aws//modules/billing-bucket"
  version = "0.4.0" # x-release-please-version

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
| protect\_raw | Deny the delete calls (`s3:DeleteObject`, `s3:DeleteObjectVersion`) on<br/>anything under `raw/`, to every principal, so a delivered bill cannot be<br/>deleted. Switch it on once the first deliveries have been checked to land<br/>under the right prefixes: until then a misplaced first object can still be<br/>cleaned up. The bucket itself always refuses destroy and replacement,<br/>whatever this is set to. | `bool` | `true` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| arn | The bucket's ARN, known at plan. |
| aws\_export\_prefix | The prefix to give an AWS Data Export (`aws-billing-export`'s `prefix`). AWS writes `<export-name>/data/` and `<export-name>/metadata/` below it. |
| name | The bucket's name. |
| normalized\_prefix | Where the normalizer writes, under `<normalized_prefix>/schema=<schema>/…`. Rebuildable from raw/. |
| raw\_prefix | Where every source delivers, under `<raw_prefix>/provider=<p>/source=<s>/`. Never deleted. |
<!-- END_TF_DOCS -->
