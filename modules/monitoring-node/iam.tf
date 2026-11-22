# The node's role: read its bundle and its parameters (the bundle name and the
# secrets), write only its status, read CloudWatch metrics (Grafana's CPU
# credit panels), and with a domain upsert its own A record. Session Manager is
# the only way in.

locals {
  secret_parameter_names = concat([var.grafana_admin.user_parameter, var.grafana_admin.password_parameter], local.extra_secret_parameters)

  policy_statements = concat(
    [
      {
        Sid      = "ReadTheBundle"
        Effect   = "Allow"
        Action   = "s3:GetObject"
        Resource = "arn:aws:s3:::${local.config_bucket}/bundles/*"
      },
      {
        Sid      = "ReadTheParameters"
        Effect   = "Allow"
        Action   = "ssm:GetParameter"
        Resource = concat(["${local.parameter_arn}${local.parameter_prefix}/config-bundle"], [for name in local.secret_parameter_names : "${local.parameter_arn}${name}"])
      },
      {
        Sid    = "WriteTheStatus"
        Effect = "Allow"
        Action = "ssm:PutParameter"
        Resource = [
          "${local.parameter_arn}${local.parameter_prefix}/status",
          "${local.parameter_arn}${local.parameter_prefix}/running-config",
        ]
      },
      {
        Sid      = "ReadMetrics"
        Effect   = "Allow"
        Action   = ["cloudwatch:GetMetricData", "cloudwatch:ListMetrics", "cloudwatch:GetMetricStatistics"]
        Resource = "*"
      },
    ],
    var.domain == null ? [] : [
      {
        Sid      = "UpdateItsDnsRecord"
        Effect   = "Allow"
        Action   = "route53:ChangeResourceRecordSets"
        Resource = "arn:aws:route53:::hostedzone/${var.zone_id}"
        Condition = {
          "ForAllValues:StringEquals" = {
            "route53:ChangeResourceRecordSetsNormalizedRecordNames" = [lower(trimsuffix(var.domain, "."))]
            "route53:ChangeResourceRecordSetsRecordTypes"           = ["A"]
            "route53:ChangeResourceRecordSetsActions"               = ["UPSERT"]
          }
        }
      },
    ],
  )
}

resource "aws_iam_role" "this" {
  name        = var.name
  description = "The monitoring node ${var.name}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "ec2.amazonaws.com" }
        Action    = "sts:AssumeRole"
      },
    ]
  })

  tags = local.tags
}

resource "aws_iam_role_policy" "this" {
  name   = "monitoring-node"
  role   = aws_iam_role.this.id
  policy = jsonencode({ Version = "2012-10-17", Statement = local.policy_statements })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "this" {
  name = var.name
  role = aws_iam_role.this.name

  tags = local.tags
}
