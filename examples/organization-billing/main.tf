# An organization's whole AWS bill, exported daily in FOCUS 1.2 from the payer
# account (111111111111) into a billing bucket in the account that runs the
# platform (222222222222).
#
# In real use the two halves are applied from separate roots, one per account,
# bucket first; this example only shows how they wire together.

provider "aws" {
  region = "us-east-1" # the bucket's account, 222222222222
}

provider "aws" {
  alias  = "payer"
  region = "us-east-1" # the payer account, 111111111111
}

module "bucket" {
  source = "../../modules/billing-bucket"

  bucket_name                   = "acme-billing"
  aws_export_source_account_ids = ["111111111111"]
}

module "export" {
  source    = "../../modules/aws-billing-export"
  providers = { aws = aws.payer }

  name                    = "acme-focus-daily"
  bucket_name             = module.bucket.name
  bucket_owner_account_id = "222222222222"
  prefix                  = module.bucket.aws_export_prefix
}

output "delivery_prefix" {
  value = module.export.delivery_prefix
}
