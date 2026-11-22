# A monitoring node served at https://grafana.example.com, in a public subnet,
# posting its alerts to Slack. Set the two Grafana parameters and the webhook
# parameter (SecureString) before the first apply.

provider "aws" {
  region = "us-east-1"
}

module "node" {
  source = "../.."

  name      = "acme-monitoring"
  vpc_id    = "vpc-0123456789abcdef0"
  subnet_id = "subnet-0123456789abcdef0"
  ami_name  = "al2023-ami-2023.12.20261026.1-kernel-6.18-arm64"

  domain  = "grafana.example.com"
  zone_id = "Z0123456789ABCDEFGHIJ"

  grafana_admin = {
    user_parameter     = "/acme/monitoring/grafana-admin-user"
    password_parameter = "/acme/monitoring/grafana-admin-password"
  }

  slack = {
    channels = { platform = "/acme/monitoring/slack/platform" }
    routes   = { host = "platform" }
  }

  # The billing bucket the billing-normalizer writes to.
  cost = { bucket = "acme-billing" }

  snapshots = { enabled = true }
}

output "grafana_url" {
  value = module.node.grafana_url
}
