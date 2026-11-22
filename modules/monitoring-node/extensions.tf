# Extension points the host monitoring (dashboards, alert rules, Slack) fills
# in: more files for the bundle, more secrets for the reconciler to read, and
# their parameters for the node's role.

locals {
  extra_bundle_files      = {}
  extra_bundle_secrets    = {}
  extra_secret_parameters = []
}
