# The billing normalizer over the bucket acme-billing, with all three sources:
# the organization's AWS export, a Databricks account's system tables, and
# task-run event records.

provider "aws" {
  region = "us-east-1"
}

module "normalizer" {
  source = "../.."

  name        = "acme-billing-normalizer"
  bucket_name = "acme-billing"

  aws = {
    delivery_prefix = "raw/provider=aws/source=data-exports/acme-focus-daily"
  }

  databricks = {
    workspace_projects = { "acme-shared" = "platform" }
  }

  runs = {
    prefixes  = ["raw/provider=acme/source=task-runs"]
    join_tags = ["RunId", "TaskId"]
  }
}

output "function_name" {
  value = module.normalizer.function_name
}
