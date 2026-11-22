# monitoring-node

Part of [`Jaws-Platform/jaws-monitoring/aws`](https://registry.terraform.io/modules/Jaws-Platform/jaws-monitoring/aws/latest) · [Registry](https://registry.terraform.io/modules/Jaws-Platform/jaws-monitoring/aws/latest/submodules/monitoring-node) · [Source](https://github.com/Jaws-Platform/terraform-aws-jaws-monitoring/tree/main/modules/monitoring-node)

One small Graviton instance running the monitoring stack in Docker Compose:
Grafana (on Postgres), Prometheus, node-exporter, cAdvisor and
postgres-exporter, and, with a `domain`, Caddy for HTTPS and a blackbox probe
of the public address. Its state lives on a separate data volume, and its
configuration arrives as a content-addressed bundle, so a dashboard or
alerting change never replaces the instance.

What it creates:

- **the instance**: the Amazon Linux 2023 arm64 image named `ami_name`,
  IMDSv2 only (hop limit 2, so containers reach the instance role), standard
  CPU credits, an encrypted gp3 root volume, a public IPv4 address, a role
  with Session Manager and nothing else to reach it by;
- **the data volume** `<name>-data` (encrypted gp3), mounted at `/data` and
  kept when the instance is replaced, with optional daily snapshots;
- **the security group**: no ingress at all without a `domain`; with one,
  443 and 80 (Let's Encrypt and the redirect) only;
- **the DNS record** (with a `domain`): the node upserts its own address at
  every boot, because it changes on every stop and start; its role may
  change only that one A record;
- **the config bucket** `<name>-config-<account>` and the parameters
  `/<name>/node/config-bundle`, `status` and `running-config`.

Every resource carries `Name` and `Component = "monitoring"`; every other tag
comes from the caller's provider `default_tags`.

## How a change rolls out

Terraform renders every file the stack runs with (`compose.yaml`,
Prometheus, Caddy, Grafana provisioning) into one JSON bundle, stores it at
`bundles/<sha256>.json` and names it in `/<name>/node/config-bundle`. The
reconciler on the node (`monitoring-reconcile`, at boot and every 5 minutes)
converges to it:

1. it first starts the current release with the values it last ran with, so
   the stack comes up even when S3 or SSM can't be reached;
2. it reads the bundle name and the secrets the bundle names; if neither
   changed, that is all. Otherwise it downloads the bundle and makes the
   values it generates once (the Postgres password, kept on the data
   volume);
3. it writes the new release and pulls its images, retried five times; until
   all of that worked, the running stack is untouched;
4. it saves the values, swaps the release in and runs `docker compose up -d`;
   config is mounted through `/data/config/current` and each service is
   labelled with a hash of the files it mounts, so only the services whose
   files changed are recreated. A rotated Grafana admin password is then
   applied with `grafana cli admin reset-admin-password`.

What the node runs is recorded on its root volume, with the values it runs
with, so a replaced instance always reconciles in full.

`/<name>/node/status` says how it went, and is written only when it changes:
`ok`, or `failed:missing secret <parameter>`, `failed:bundle <problem>`,
`failed:pull`, `failed:up` (also when the running stack will not start),
`failed:password-reset` or `failed:internal <error>`. `monitoring-reconcile
--force` reconciles in full even when nothing changed. To
apply a change at once instead of within 5 minutes, start
`monitoring-reconcile.service` through Session Manager.

Changing the bootstrap (`ami_name`, the Compose plugin, the scripts)
replaces the instance; the new one reattaches the data volume and carries
on. Container images are pinned by digest; a version bump is a bundle
change, not an instance replacement.

## Before the first apply

Set the two SecureString parameters `grafana_admin` names, the admin user
name and password, encrypted with the default `aws/ssm` key (the role is
granted no other key). Until they exist the node reports
`failed:missing secret <parameter>` and starts nothing new. To rotate the
password, change the parameter: within 5 minutes the node applies it. The
role can read only the parameters the module names, not the account's other
SecureStrings: it gets Session Manager's own actions, not the
`AmazonSSMManagedInstanceCore` policy.

## Reaching Grafana

With a `domain`, at `https://<domain>`. Without one, through a port forward:

```sh
aws ssm start-session --target <instance_id> \
  --document-name AWS-StartPortForwardingSession \
  --parameters portNumber=3000,localPortNumber=3000
```

## Recovery

| Event | What happens | What's lost |
|---|---|---|
| Stop and start | The disks persist; the stack comes back, and DNS follows the new address | Metrics for the time it was off |
| Reboot or EC2 recovery | Same disks, same instance | Minutes of metrics |
| Instance replaced | The new instance reattaches the data volume and carries on | Minutes of metrics |
| Data volume lost | Dashboards and alerts are reprovisioned from the bundle; Grafana users other than the admin must be added again | Prometheus history since the last snapshot |

## Usage

```hcl
module "monitoring_node" {
  source  = "Jaws-Platform/jaws-monitoring/aws//modules/monitoring-node"
  version = "0.3.0" # x-release-please-version

  name      = "acme-monitoring"
  vpc_id    = "vpc-0123456789abcdef0"
  subnet_id = "subnet-0123456789abcdef0"
  ami_name  = "al2023-ami-2023.12.20261026.1-kernel-6.18-arm64"
  domain    = "grafana.example.com"
  zone_id   = "Z0123456789ABCDEFGHIJ"

  grafana_admin = {
    user_parameter     = "/acme/monitoring/grafana-admin-user"
    password_parameter = "/acme/monitoring/grafana-admin-password"
  }
}
```

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

| Name | Source | Version |
| ---- | ------ | ------- |
| grafana | ./grafana | n/a |

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
| grafana\_admin | The SSM SecureString parameters (default aws/ssm key) holding Grafana's admin user name and password. Set them before the first apply. The node checks them every 5 minutes; a changed password is applied with Grafana's admin password reset. | <pre>object({<br/>    user_parameter     = string<br/>    password_parameter = string<br/>  })</pre> | n/a | yes |
| name | Names the instance, its role, security group, data volume (`<name>-data`), config bucket (`<name>-config-<account>`) and parameters (`/<name>/node/…`). | `string` | n/a | yes |
| subnet\_id | A public subnet for the node. The data volume is created in its availability zone, so moving the node to another zone means a new volume. | `string` | n/a | yes |
| vpc\_id | The VPC of the node's subnet. | `string` | n/a | yes |
| acme\_email | Optional contact address for Let's Encrypt. | `string` | `null` | no |
| data\_volume\_gb | Size of the data volume: Prometheus, Postgres, Grafana and Caddy's state, kept when the instance is replaced. | `number` | `30` | no |
| domain | The name Grafana is served at over HTTPS (Caddy, Let's Encrypt). Null: no ingress at all; reach Grafana through a Session Manager port forward. | `string` | `null` | no |
| extra\_alert\_rules | More alert rules: a name to a Grafana alerting provisioning document (YAML), provisioned as rules-extra-<name>.json. Every rule needs labels area (host, pipeline or cost) and severity (warning or critical). To remove a rule, keep its uid under deleteRules in the same document. | `map(string)` | `{}` | no |
| extra\_dashboards | More dashboards to provision: "<Folder>/<name>.json" (the folder is created in Grafana) to the dashboard's JSON, which needs a uid and a title. | `map(string)` | `{}` | no |
| images | Container images to use instead of the module's digest-pinned defaults, by service name (see the README). | `map(string)` | `{}` | no |
| instance\_type | The instance type, arm64 (Graviton). A T type runs with standard CPU credits, so a burst never bills extra; watch its credit balance. | `string` | `"t9g.medium"` | no |
| prometheus\_retention | How long Prometheus keeps metrics, and the size it never grows past (the oldest data is dropped first). Keep size\_gb well under data\_volume\_gb. | <pre>object({<br/>    time    = optional(string, "365d")<br/>    size_gb = optional(number, 12)<br/>  })</pre> | `{}` | no |
| root\_volume\_gb | Size of the root volume: the OS, the images and a 2 GB swap file. | `number` | `12` | no |
| snapshots | Daily snapshots of the data volume (Data Lifecycle Manager), at time\_utc, keeping the last `keep`. | <pre>object({<br/>    enabled  = optional(bool, false)<br/>    time_utc = optional(string, "03:00")<br/>    keep     = optional(number, 7)<br/>  })</pre> | `{}` | no |
| thresholds | Alert thresholds, which also set the dashboard's tile colours and dashed lines. Every attribute is optional and defaults to spec 6.8's numbers. Percentages are of the resource; cpu\_credits\_percent is of the instance type's maximum balance; container\_restarts counts restarts in 15 minutes; the *\_days are days. prometheus\_history\_days warns only while Prometheus is above prometheus\_size\_percent of its size cap, i.e. when the cap is costing history. | <pre>object({<br/>    cpu_percent             = optional(object({ warning = number, critical = number }), { warning = 60, critical = 85 })<br/>    cpu_credits_percent     = optional(object({ warning = number, critical = number }), { warning = 25, critical = 5 })<br/>    memory_percent          = optional(object({ warning = number, critical = number }), { warning = 70, critical = 90 })<br/>    swap_percent            = optional(object({ warning = number, critical = number }), { warning = 25, critical = 75 })<br/>    disk_percent            = optional(object({ warning = number, critical = number }), { warning = 70, critical = 90 })<br/>    disk_full_days          = optional(object({ warning = number, critical = number }), { warning = 7, critical = 2 })<br/>    inodes_percent          = optional(object({ warning = number, critical = number }), { warning = 70, critical = 90 })<br/>    prometheus_size_percent = optional(object({ warning = number }), { warning = 85 })<br/>    prometheus_history_days = optional(object({ warning = number }), { warning = 90 })<br/>    container_restarts      = optional(object({ warning = number, critical = number }), { warning = 1, critical = 3 })<br/>    tls_days                = optional(object({ warning = number, critical = number }), { warning = 14, critical = 3 })<br/>    os_release_update_days  = optional(object({ warning = number }), { warning = 7 })<br/>  })</pre> | `{}` | no |
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
