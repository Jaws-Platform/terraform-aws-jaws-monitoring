# monitoring-node

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| terraform | >= 1.11 |
| aws | ~> 6.0 |

## Providers

| Name | Version |
| ---- | ------- |
| aws | ~> 6.0 |

## Modules

No modules.

## Resources

| Name | Type |
| ---- | ---- |
| [aws_dlm_lifecycle_policy.snapshots](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/dlm_lifecycle_policy) | resource |
| [aws_ebs_volume.data](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ebs_volume) | resource |
| [aws_iam_instance_profile.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_instance_profile) | resource |
| [aws_iam_role.snapshots](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy_attachment.snapshots](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.ssm](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_instance.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/instance) | resource |
| [aws_route53_record.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route53_record) | resource |
| [aws_s3_bucket.config](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket) | resource |
| [aws_s3_bucket_lifecycle_configuration.config](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_lifecycle_configuration) | resource |
| [aws_s3_bucket_ownership_controls.config](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_ownership_controls) | resource |
| [aws_s3_bucket_public_access_block.config](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_public_access_block) | resource |
| [aws_s3_bucket_server_side_encryption_configuration.config](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_server_side_encryption_configuration) | resource |
| [aws_s3_bucket_versioning.config](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_versioning) | resource |
| [aws_s3_object.bundle](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_object) | resource |
| [aws_security_group.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
| [aws_ssm_parameter.config_bundle](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ssm_parameter) | resource |
| [aws_ssm_parameter.running_config](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ssm_parameter) | resource |
| [aws_ssm_parameter.status](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ssm_parameter) | resource |
| [aws_volume_attachment.data](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/volume_attachment) | resource |
| [aws_vpc_security_group_egress_rule.all](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_egress_rule) | resource |
| [aws_vpc_security_group_ingress_rule.web](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_ingress_rule) | resource |
| [aws_ami.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/ami) | data source |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |
| [aws_subnet.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/subnet) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| ami\_name | The exact name of the Amazon Linux 2023 arm64 image to run, e.g. `al2023-ami-2023.12.20261026.1-kernel-6.18-arm64`. Changing it replaces the instance; the data volume is reattached. | `string` | n/a | yes |
| grafana\_admin | The SSM SecureString parameters holding Grafana's admin user name and password. The node reads them at every reconcile; set them before the first apply. | <pre>object({<br/>    user_parameter     = string<br/>    password_parameter = string<br/>  })</pre> | n/a | yes |
| name | Names the instance, its role, security group, data volume (`<name>-data`), config bucket (`<name>-config-<account>`) and parameters (`/<name>/node/…`). | `string` | n/a | yes |
| subnet\_id | A public subnet for the node. The data volume is created in its availability zone, so moving the node to another zone means a new volume. | `string` | n/a | yes |
| vpc\_id | The VPC of the node's subnet. | `string` | n/a | yes |
| acme\_email | Optional contact address for Let's Encrypt. | `string` | `null` | no |
| data\_volume\_gb | Size of the data volume: Prometheus, Postgres, Grafana and Caddy's state, kept when the instance is replaced. | `number` | `30` | no |
| domain | The name Grafana is served at over HTTPS (Caddy, Let's Encrypt). Null: no ingress at all; reach Grafana through a Session Manager port forward. | `string` | `null` | no |
| images | Container images to use instead of the module's digest-pinned defaults, by service name (see the README). | `map(string)` | `{}` | no |
| instance\_type | The instance type, arm64 (Graviton). A T type runs with standard CPU credits, so a burst never bills extra; watch its credit balance. | `string` | `"t9g.medium"` | no |
| prometheus\_retention | How long Prometheus keeps metrics, and the size it never grows past (the oldest data is dropped first). Keep size\_gb well under data\_volume\_gb. | <pre>object({<br/>    time    = optional(string, "365d")<br/>    size_gb = optional(number, 12)<br/>  })</pre> | `{}` | no |
| root\_volume\_gb | Size of the root volume: the OS, the images and a 2 GB swap file. | `number` | `12` | no |
| snapshots | Daily snapshots of the data volume (Data Lifecycle Manager), at time\_utc, keeping the last `keep`. | <pre>object({<br/>    enabled  = optional(bool, false)<br/>    time_utc = optional(string, "03:00")<br/>    keep     = optional(number, 7)<br/>  })</pre> | `{}` | no |
| zone\_id | The Route 53 hosted zone of `domain`. The node may only upsert its own A record there, at every boot. | `string` | `null` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| config\_bucket | The bucket holding the node's config bundles. |
| data\_volume\_id | The data volume, kept when the instance is replaced. |
| grafana\_url | Where Grafana is: the domain over HTTPS, or a Session Manager port forward to localhost:3000. |
| instance\_id | The node's instance. |
| parameter\_prefix | The node's SSM parameters: config-bundle (what it should run), status and running-config (what it reports). |
| public\_ip | The node's public IPv4 address at creation; it changes on stop and start (the DNS record follows it). |
| role\_arn | The node's instance role ARN. |
| role\_name | The node's instance role. |
| security\_group\_id | The node's security group. |
<!-- END_TF_DOCS -->
