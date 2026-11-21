# The AWS billing export: FOCUS 1.2 with AWS columns, daily, Parquet, every
# refresh in new files, delivered to a bucket that may be in another account.
# Mock provider: nothing is called.

mock_provider "aws" {}

variables {
  name        = "acme-focus-daily"
  bucket_name = "acme-billing"
}

run "defaults_are_focus_1_2_daily_parquet_in_new_files" {
  command = plan

  assert {
    condition     = startswith(aws_bcmdataexports_export.this.export[0].data_query[0].query_statement, "SELECT AvailabilityZone, BilledCost, BillingAccountId, ") && endswith(aws_bcmdataexports_export.this.export[0].data_query[0].query_statement, ", SubAccountType, Tags, x_Discounts, x_Operation, x_ServiceCode FROM FOCUS_1_2_AWS")
    error_message = "the query selects the FOCUS 1.2 columns, listed explicitly, from FOCUS_1_2_AWS"
  }

  assert {
    condition     = length(split(", ", trimsuffix(trimprefix(aws_bcmdataexports_export.this.export[0].data_query[0].query_statement, "SELECT "), " FROM FOCUS_1_2_AWS"))) == 60
    error_message = "all 60 columns of FOCUS_1_2_AWS"
  }

  assert {
    condition     = aws_bcmdataexports_export.this.export[0].data_query[0].table_configurations == tomap({ FOCUS_1_2_AWS = tomap({ TIME_GRANULARITY = "DAILY" }) })
    error_message = "daily granularity"
  }

  assert {
    condition = aws_bcmdataexports_export.this.export[0].destination_configurations[0].s3_destination[0].s3_output_configurations[0] == {
      compression = "PARQUET"
      format      = "PARQUET"
      output_type = "CUSTOM"
      overwrite   = "CREATE_NEW_REPORT"
    }
    error_message = "Parquet, and every refresh in new files, so a delivery is never overwritten"
  }

  assert {
    condition     = aws_bcmdataexports_export.this.export[0].refresh_cadence[0].frequency == "SYNCHRONOUS"
    error_message = "refreshed whenever the bill changes"
  }

  assert {
    condition     = aws_bcmdataexports_export.this.export[0].destination_configurations[0].s3_destination[0].s3_bucket == "acme-billing" && aws_bcmdataexports_export.this.export[0].destination_configurations[0].s3_destination[0].s3_prefix == "raw/provider=aws/source=data-exports" && aws_bcmdataexports_export.this.export[0].destination_configurations[0].s3_destination[0].s3_region == "us-east-1"
    error_message = "delivered under the bucket's AWS prefix in us-east-1"
  }

  assert {
    condition     = aws_bcmdataexports_export.this.tags == tomap({ Name = "acme-focus-daily", Component = "billing" })
    error_message = "the module sets Name and Component only"
  }

  assert {
    condition     = output.delivery_prefix == "raw/provider=aws/source=data-exports/acme-focus-daily"
    error_message = "AWS writes data/ and metadata/ under <prefix>/<name>"
  }
}

run "same_account_leaves_the_bucket_owner_unset" {
  command = plan

  assert {
    condition     = aws_bcmdataexports_export.this.export[0].destination_configurations[0].s3_destination[0].s3_bucket_owner == null
    error_message = "no bucket owner for a bucket in the same account"
  }
}

run "cross_account_names_the_bucket_owner" {
  command = plan

  variables {
    bucket_owner_account_id = "222222222222"
  }

  assert {
    condition     = aws_bcmdataexports_export.this.export[0].destination_configurations[0].s3_destination[0].s3_bucket_owner == "222222222222"
    error_message = "a bucket in another account is named with its owner"
  }
}

run "granularity_is_an_input" {
  command = plan

  variables {
    time_granularity = "HOURLY"
  }

  assert {
    condition     = aws_bcmdataexports_export.this.export[0].data_query[0].table_configurations == tomap({ FOCUS_1_2_AWS = tomap({ TIME_GRANULARITY = "HOURLY" }) })
    error_message = "time_granularity sets TIME_GRANULARITY"
  }
}

run "rejects_prefixes_with_stray_slashes" {
  command = plan

  variables {
    prefix = "/raw//aws/"
  }

  expect_failures = [var.prefix]
}

run "rejects_a_malformed_bucket_owner" {
  command = plan

  variables {
    bucket_owner_account_id = "2222"
  }

  expect_failures = [var.bucket_owner_account_id]
}

run "rejects_an_unknown_granularity" {
  command = plan

  variables {
    time_granularity = "WEEKLY"
  }

  expect_failures = [var.time_granularity]
}

run "rejects_an_invalid_export_name" {
  command = plan

  variables {
    name = "acme focus/daily"
  }

  expect_failures = [var.name]
}
