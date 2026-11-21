# Organization billing

An organization's whole AWS bill, exported every day in the FOCUS 1.2 schema
from the payer account into a billing bucket owned by another account: the
one that runs the monitoring platform.

```text
 payer account 111111111111                 platform account 222222222222
 ┌─────────────────────────────┐            ┌────────────────────────────────────────────┐
 │ aws-billing-export          │  delivers  │ billing-bucket: acme-billing                │
 │ acme-focus-daily (DAILY)    │ ─────────► │ raw/provider=aws/source=data-exports/       │
 └─────────────────────────────┘            │   acme-focus-daily/data/BILLING_PERIOD=…/   │
                                            └────────────────────────────────────────────┘
```

In real use the two halves are applied from separate roots, one per account,
in this order:

1. In the platform account, the bucket, with the payer account in
   `aws_export_source_account_ids`.
2. In the payer account, the export, with `bucket_owner_account_id` set to
   the platform account and `prefix` set to the bucket's
   `aws_export_prefix`.

This example puts both in one configuration with two providers, only to show
how they wire together.
