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

So far it holds the cost pipeline: the bucket every source delivers into, the
organization-wide AWS export, and the normalizer that turns every delivery into
one table. It is one of the
[Jaws](https://github.com/Jaws-Platform/jaws) module families, and has no
dependency on Jaws: names, accounts and prefixes are plain inputs.

## Submodules

| Submodule | What it is | Applied in |
|---|---|---|
| [`billing-bucket`](https://github.com/Jaws-Platform/terraform-aws-jaws-monitoring/tree/main/modules/billing-bucket) | The bucket every billing source delivers into. Raw deliveries are never deleted; the normalized layer is rebuildable from them | the account that runs the platform |
| [`aws-billing-export`](https://github.com/Jaws-Platform/terraform-aws-jaws-monitoring/tree/main/modules/aws-billing-export) | The FOCUS 1.2 daily AWS Data Export, in Parquet, delivered to that bucket, across accounts if needed | the account whose bill it exports: the payer, for every account of an organization |
| [`billing-normalizer`](https://github.com/Jaws-Platform/terraform-aws-jaws-monitoring/tree/main/modules/billing-normalizer) | An hourly Lambda that rebuilds each changed billing period of every source as FOCUS-aligned Parquet, and task-run records as an event table | the account that runs the platform |
| [`monitoring-node`](https://github.com/Jaws-Platform/terraform-aws-jaws-monitoring/tree/main/modules/monitoring-node) | One Graviton instance running Grafana (on Postgres), Prometheus and the exporters in Docker Compose, with a separate data volume, optional HTTPS, a host health dashboard, host alert rules and Slack routing, and a config bundle that changes without replacing the instance | the account that runs the platform |

The root module creates nothing yet. A later release makes it the all-in-one
composition. [`examples/organization-billing`](https://github.com/Jaws-Platform/terraform-aws-jaws-monitoring/tree/main/examples/organization-billing)
shows the two submodules wired together across a payer and a platform
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
                                           #   <export-name>/data/BILLING_PERIOD=YYYY-MM/<timestamp>-<execution-id>/…
                                           #   <export-name>/metadata/BILLING_PERIOD=YYYY-MM/Manifest.json
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

## Providers

No providers.

## Modules

No modules.

## Resources

No resources.

## Inputs

No inputs.

## Outputs

No outputs.
<!-- END_TF_DOCS -->
