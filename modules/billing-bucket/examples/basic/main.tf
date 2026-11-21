# A billing bucket that the payer account 111111111111 may deliver its AWS
# Data Export into.

provider "aws" {
  region = "us-east-1"
}

module "billing" {
  source = "../.."

  bucket_name                   = "acme-billing"
  aws_export_source_account_ids = ["111111111111"]
}

output "bucket_name" {
  value = module.billing.name
}

output "aws_export_prefix" {
  value = module.billing.aws_export_prefix
}
