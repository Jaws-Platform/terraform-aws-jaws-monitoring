output "name" {
  description = "The bucket's name."
  value       = aws_s3_bucket.this.bucket
}

output "arn" {
  description = "The bucket's ARN, known at plan."
  value       = local.arn
}

output "raw_prefix" {
  description = "Where every source delivers, under `<raw_prefix>/provider=<p>/source=<s>/`. Never deleted."
  value       = "raw"
}

output "aws_export_prefix" {
  description = "The prefix to give an AWS Data Export (`aws-billing-export`'s `prefix`). AWS writes `<export-name>/data/` and `<export-name>/metadata/` below it."
  value       = local.aws_export_prefix
}

output "normalized_prefix" {
  description = "Where the normalizer writes, under `<normalized_prefix>/schema=<schema>/…`. Rebuildable from raw/."
  value       = "normalized"
}
