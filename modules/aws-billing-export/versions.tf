terraform {
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # s3_bucket_owner (cross-account delivery) was verified in 6.73.0.
      version = ">= 6.73, < 7.0"
    }
  }
}
