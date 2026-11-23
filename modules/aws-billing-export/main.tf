# An AWS Data Export of FOCUS 1.2 with AWS columns.
#
# Create it in the account whose bill it exports: the payer (management)
# account exports every account of the organization; a member account exports
# only its own usage, and only since it joined. The bucket may be in another
# account (bucket_owner_account_id); create the bucket and its policy first.
#
# Every refresh is written to new files (CREATE_NEW_REPORT):
#
#   <prefix>/<name>/data/billing_period=YYYY-MM/<timestamp>-<execution-id>/<name>-00001.snappy.parquet
#   <prefix>/<name>/metadata/billing_period=YYYY-MM/Manifest.json   (always the newest execution)
#
# AWS refreshes the current month at least daily and may restate the previous
# month for two weeks after it ends; nothing already delivered is overwritten.

resource "aws_bcmdataexports_export" "this" {
  export {
    name        = var.name
    description = var.description

    data_query {
      query_statement = "SELECT ${join(", ", local.focus_1_2_aws_columns)} FROM FOCUS_1_2_AWS"
      table_configurations = {
        FOCUS_1_2_AWS = {
          TIME_GRANULARITY = var.time_granularity
        }
      }
    }

    destination_configurations {
      s3_destination {
        s3_bucket       = var.bucket_name
        s3_bucket_owner = var.bucket_owner_account_id
        s3_prefix       = var.prefix
        s3_region       = var.bucket_region

        s3_output_configurations {
          compression = "PARQUET"
          format      = "PARQUET"
          output_type = "CUSTOM"
          overwrite   = "CREATE_NEW_REPORT"
        }
      }
    }

    refresh_cadence {
      frequency = "SYNCHRONOUS"
    }
  }

  tags = {
    Name      = var.name
    Component = "billing"
  }
}
