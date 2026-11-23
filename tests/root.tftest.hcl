# The root module: the billing normalizer and the monitoring node, wired
# together. Mock providers: nothing is called.

mock_provider "aws" {
  override_during = plan

  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
    }
  }

  mock_data "aws_region" {
    defaults = {
      region = "us-east-1"
    }
  }

  mock_data "aws_subnet" {
    defaults = {
      availability_zone = "us-east-1a"
    }
  }

  mock_data "aws_ami" {
    defaults = {
      id = "ami-0123456789abcdef0"
    }
  }

  mock_resource "aws_instance" {
    defaults = {
      id        = "i-0123456789abcdef0"
      public_ip = "198.51.100.7"
    }
  }

  mock_resource "aws_ebs_volume" {
    defaults = {
      id = "vol-0123456789abcdef0"
    }
  }

  mock_resource "aws_acm_certificate" {
    defaults = {
      arn = "arn:aws:acm:us-east-1:123456789012:certificate/00000000-0000-0000-0000-000000000000"
      domain_validation_options = [{
        domain_name           = "grafana.example.com"
        resource_record_name  = "_0123456789abcdef.grafana.example.com."
        resource_record_type  = "CNAME"
        resource_record_value = "_fedcba9876543210.acm-validations.aws."
      }]
    }
  }

  mock_resource "aws_cloudfront_distribution" {
    defaults = {
      domain_name    = "d111111abcdef8.cloudfront.net"
      hosted_zone_id = "Z2FDTNDATAQYW2"
    }
  }

  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/acme-monitoring"
    }
  }
}

mock_provider "archive" {}

variables {
  name        = "acme-monitoring"
  bucket_name = "acme-billing"
  vpc_id      = "vpc-0123"
  subnet_id   = "subnet-0123"
  ami_name    = "al2023-ami-2023.12.20261026.1-kernel-6.18-arm64"
  grafana_admin = {
    user_parameter     = "/acme/monitoring/grafana-admin-user"
    password_parameter = "/acme/monitoring/grafana-admin-password"
  }
}

run "the_root_plans_with_only_the_required_inputs" {
  command = plan

  variables {
    aws = { delivery_prefix = "raw/provider=aws/source=data-exports/acme-focus-daily" }
  }

  assert {
    condition     = output.node.instance_id == "i-0123456789abcdef0" && output.normalizer.function_name == "acme-monitoring-normalizer"
    error_message = "every input left out takes its submodule's default: the node and the normalizer both plan"
  }
}

run "the_root_wires_the_normalizer_into_the_node" {
  command = plan

  variables {
    aws        = { delivery_prefix = "raw/provider=aws/source=data-exports/acme-focus-daily" }
    databricks = {}
    runs       = { prefixes = ["raw/provider=jaws"], join_tags = ["RunId", "TaskId"] }
  }

  assert {
    condition     = local.node_cost.bucket == "acme-billing" && local.node_cost.normalized_prefix == "normalized" && jsonencode(sort(local.node_cost.providers)) == jsonencode(["aws", "databricks"]) && jsonencode(local.node_cost.run_join_tags) == jsonencode(["RunId", "TaskId"])
    error_message = "the node reads what the normalizer writes, expects its providers, and joins runs on its tags"
  }
}

run "a_databricks_only_root_expects_only_databricks" {
  command = plan

  variables {
    databricks = {}
  }

  assert {
    condition     = jsonencode(local.node_cost.providers) == jsonencode(["databricks"])
    error_message = "with no AWS source, the node expects no AWS charges"
  }
}

run "the_root_passes_the_off_hours_page_to_the_node" {
  command = plan

  variables {
    aws            = { delivery_prefix = "raw/provider=aws/source=data-exports/acme-focus-daily" }
    domain         = "grafana.example.com"
    zone_id        = "Z123"
    off_hours_page = true
    schedule       = { timezone = "America/Denver", days = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"], on = "08:00", off = "24:00" }
  }

  assert {
    condition     = output.off_hours_page_domain_name != null
    error_message = "off_hours_page reaches the node: its distribution exists"
  }
}
