# No ingress unless the node serves HTTPS: then 443, and 80 for Let's Encrypt
# and the redirect, from anywhere. Everything else (Prometheus, Postgres, the
# exporters) listens only on the Docker network or the host.

locals {
  web_ingress = var.domain == null ? {} : {
    "https-ipv4" = { port = 443, cidr_ipv4 = "0.0.0.0/0", cidr_ipv6 = null }
    "https-ipv6" = { port = 443, cidr_ipv4 = null, cidr_ipv6 = "::/0" }
    "http-ipv4"  = { port = 80, cidr_ipv4 = "0.0.0.0/0", cidr_ipv6 = null }
    "http-ipv6"  = { port = 80, cidr_ipv4 = null, cidr_ipv6 = "::/0" }
  }
}

resource "aws_security_group" "this" {
  name        = var.name
  description = var.domain == null ? "${var.name}: egress only" : "${var.name}: HTTPS (and HTTP for ACME) in, egress"
  vpc_id      = var.vpc_id

  tags = local.tags
}

resource "aws_vpc_security_group_ingress_rule" "web" {
  for_each = local.web_ingress

  security_group_id = aws_security_group.this.id
  description       = "${upper(split("-", each.key)[0])} to ${var.domain}"
  ip_protocol       = "tcp"
  from_port         = each.value.port
  to_port           = each.value.port
  cidr_ipv4         = each.value.cidr_ipv4
  cidr_ipv6         = each.value.cidr_ipv6

  tags = local.tags
}

resource "aws_vpc_security_group_egress_rule" "all" {
  for_each = {
    ipv4 = { cidr_ipv4 = "0.0.0.0/0", cidr_ipv6 = null }
    ipv6 = { cidr_ipv4 = null, cidr_ipv6 = "::/0" }
  }

  security_group_id = aws_security_group.this.id
  description       = "Image pulls, OS updates and AWS APIs"
  ip_protocol       = "-1"
  cidr_ipv4         = each.value.cidr_ipv4
  cidr_ipv6         = each.value.cidr_ipv6

  tags = local.tags
}

# The node upserts its own address here at every boot (its public IPv4 address
# changes on stop and start); Terraform only creates the record. With
# off_hours_page, the scheduler turns it into an alias to the off-hours page at
# each stop, so Terraform ignores the alias too.
resource "aws_route53_record" "this" {
  count = var.domain == null ? 0 : 1

  zone_id = var.zone_id
  name    = var.domain
  type    = "A"
  ttl     = 60
  records = [aws_instance.this.public_ip]

  lifecycle {
    ignore_changes = [records, ttl, alias]
  }
}
