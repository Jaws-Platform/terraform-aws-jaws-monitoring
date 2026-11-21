# The organization's FOCUS 1.2 daily export, created in the payer account and
# delivered to a billing bucket owned by the account 222222222222.

provider "aws" {
  region = "us-east-1" # the payer account
}

module "export" {
  source = "../.."

  name                    = "acme-focus-daily"
  bucket_name             = "acme-billing"
  bucket_owner_account_id = "222222222222"
}

output "delivery_prefix" {
  value = module.export.delivery_prefix
}
