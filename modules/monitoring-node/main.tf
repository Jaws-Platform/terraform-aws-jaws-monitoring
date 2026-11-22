# The monitoring node: one Graviton instance running the monitoring stack in
# Docker Compose, with its state on a separate data volume.
#
#   instance      AL2023 arm64 by name, IMDSv2 only, standard CPU credits
#   data volume   /data: Prometheus, Postgres, Grafana and Caddy's state; kept
#                 when the instance is replaced
#   config        a content-addressed bundle in the config bucket, named by
#                 /<name>/node/config-bundle; the reconciler on the node converges
#                 to it at boot and every 5 minutes, so a change never replaces
#                 the instance
#   access        Session Manager only; with a domain, HTTPS (443, 80 for ACME)

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

data "aws_subnet" "this" {
  id = var.subnet_id
}

data "aws_ami" "this" {
  owners      = ["amazon"]
  most_recent = true
  # The image is pinned by name, and Amazon deprecates old images: keep
  # resolving the pinned one until a pull request bumps ami_name.
  include_deprecated = true

  filter {
    name   = "name"
    values = [var.ami_name]
  }

  filter {
    name   = "architecture"
    values = ["arm64"]
  }
}

locals {
  account_id       = data.aws_caller_identity.current.account_id
  region           = data.aws_region.current.region
  parameter_prefix = "/${var.name}/node"
  parameter_arn    = "arn:aws:ssm:${local.region}:${local.account_id}:parameter"
  config_bucket    = "${var.name}-config-${local.account_id}"
  data_volume_name = "${var.name}-data"
  burstable        = startswith(var.instance_type, "t")

  tags = {
    Name      = var.name
    Component = "monitoring"
  }
}

resource "aws_instance" "this" {
  ami = data.aws_ami.this.id
  # tflint-ignore: aws_instance_invalid_type # the ruleset (0.49.0) predates T9g (GA 2026-11-20)
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = [aws_security_group.this.id]
  iam_instance_profile        = aws_iam_instance_profile.this.name
  associate_public_ip_address = true

  user_data                   = local.user_data
  user_data_replace_on_change = true

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
    http_endpoint               = "enabled"
  }

  dynamic "credit_specification" {
    for_each = local.burstable ? [1] : []
    content {
      cpu_credits = "standard"
    }
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_gb
    encrypted   = true
    tags        = merge(local.tags, { Name = "${var.name}-root" })
  }

  tags = local.tags
}

resource "aws_ssm_parameter" "config_bundle" {
  name        = "${local.parameter_prefix}/config-bundle"
  description = "The config bundle ${var.name} converges to (a key in ${local.config_bucket})"
  type        = "String"
  value       = aws_s3_object.bundle.key

  tags = local.tags
}

# Written by the reconciler on the node; Terraform only creates them.
resource "aws_ssm_parameter" "status" {
  name        = "${local.parameter_prefix}/status"
  description = "The reconciler's last result on ${var.name}: ok or failed:<reason>"
  type        = "String"
  value       = "pending"

  tags = local.tags

  lifecycle {
    ignore_changes = [value]
  }
}

resource "aws_ssm_parameter" "running_config" {
  name        = "${local.parameter_prefix}/running-config"
  description = "The config bundle running on ${var.name}"
  type        = "String"
  value       = "none"

  tags = local.tags

  lifecycle {
    ignore_changes = [value]
  }
}
