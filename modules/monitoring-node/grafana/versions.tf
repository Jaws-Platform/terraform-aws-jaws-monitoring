# No providers: this module only renders files, so it plans and applies with no
# cloud at all (the smoke test relies on that).
terraform {
  required_version = ">= 1.11"
}
