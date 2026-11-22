# Filled in by later tasks of the plan: the bootstrap (user data) and the bundle.

locals {
  extra_secret_parameters = []
  bundle_json = jsonencode({
    schema    = "monitoring-bundle-1"
    files     = {}
    secrets   = {}
    generated = []
    pending   = { acme_email = var.acme_email, retention = var.prometheus_retention, images = var.images }
  })
}
