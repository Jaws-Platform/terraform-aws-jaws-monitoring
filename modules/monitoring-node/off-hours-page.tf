# The optional off-hours page. A stopped node releases its public address, but
# its DNS record still points at it, so browsers hang overnight. With
# `off_hours_page`, a CloudFront function answers every request for the domain
# with a 503 page that says when Grafana is back, and at each scheduled stop an
# EventBridge Scheduler schedule upserts the domain as an alias to it. The
# node's own upsert at boot points the name back. CloudFront certificates live
# in us-east-1, so the caller's provider must be there. Nothing here costs
# beyond the free tiers: no bucket, no Lambda, no health check.

locals {
  off_hours_page = var.off_hours_page && local.scheduled && var.domain != null
  page_name      = "${var.name}-off-hours-page"

  page_days      = local.scheduled ? [for d in local.week : title(d) if contains(var.schedule.days, d)] : []
  page_every_day = length(local.page_days) == 7
  page_days_text = local.page_every_day ? "every day" : length(local.page_days) < 2 ? join("", local.page_days) : "${join(", ", slice(local.page_days, 0, length(local.page_days) - 1))} and ${local.page_days[length(local.page_days) - 1]}"
  page_back_text = local.page_every_day ? "It's back at ${try(var.schedule.on, "")}." : "It's back at ${try(var.schedule.on, "")} on the next day it runs."

  off_hours_page_html = !local.off_hours_page ? "" : join("", [
    "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">",
    "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">",
    "<title>Off hours</title>",
    "<style>body{margin:0;min-height:100vh;display:grid;place-items:center;font-family:system-ui,sans-serif;background:#f6f7f9;color:#1f2933}",
    "main{max-width:32rem;padding:2rem}small{color:#616e7c}h1{margin:.4rem 0 1rem}p{line-height:1.5}",
    "@media(prefers-color-scheme:dark){body{background:#1b1f24;color:#e4e7eb}small{color:#9aa5b1}}</style>",
    "</head><body><main><small>${var.domain}</small><h1>Off hours</h1>",
    "<p>Grafana runs ${local.page_days_text}, ${var.schedule.on}–${var.schedule.off} (${var.schedule.timezone}).</p>",
    "<p>${local.page_back_text}</p></main></body></html>",
  ])
}

resource "aws_acm_certificate" "off_hours_page" {
  count = local.off_hours_page ? 1 : 0

  domain_name       = var.domain
  validation_method = "DNS"

  tags = merge(local.tags, { Name = local.page_name })

  lifecycle {
    create_before_destroy = true

    precondition {
      condition     = var.domain == lower(var.domain)
      error_message = "The off-hours page needs domain in lowercase, because Route 53 returns record names in lowercase."
    }

    precondition {
      condition     = local.region == "us-east-1"
      error_message = "CloudFront certificates live in us-east-1, so the off-hours page needs the provider there. Set off_hours_page = false elsewhere."
    }
  }
}

resource "aws_route53_record" "off_hours_page_validation" {
  for_each = local.off_hours_page ? { for o in aws_acm_certificate.off_hours_page[0].domain_validation_options : o.domain_name => o } : {}

  zone_id         = var.zone_id
  name            = each.value.resource_record_name
  type            = each.value.resource_record_type
  ttl             = 60
  records         = [each.value.resource_record_value]
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "off_hours_page" {
  count = local.off_hours_page ? 1 : 0

  certificate_arn         = aws_acm_certificate.off_hours_page[0].arn
  validation_record_fqdns = [for r in aws_route53_record.off_hours_page_validation : r.fqdn]
}

resource "aws_cloudfront_function" "off_hours_page" {
  count = local.off_hours_page ? 1 : 0

  name    = local.page_name
  comment = "The off-hours page"
  runtime = "cloudfront-js-2.0"
  publish = true
  code    = templatefile("${path.module}/files/off-hours-page.js.tftpl", { page = jsonencode(local.off_hours_page_html) })
}

resource "aws_cloudfront_distribution" "off_hours_page" {
  count = local.off_hours_page ? 1 : 0

  enabled     = true
  comment     = "${var.name}: off-hours page"
  aliases     = [var.domain]
  price_class = "PriceClass_100"

  # Never contacted: the function answers first. With no origin access, S3
  # would refuse anything that did reach it.
  origin {
    origin_id   = "unused"
    domain_name = aws_s3_bucket.config.bucket_regional_domain_name

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    target_origin_id       = "unused"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    cache_policy_id        = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad" # Managed-CachingDisabled

    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.off_hours_page[0].arn
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.off_hours_page[0].certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  tags = merge(local.tags, { Name = local.page_name })
}

resource "aws_iam_role_policy" "off_hours_page" {
  count = local.off_hours_page ? 1 : 0

  name = "off-hours-page"
  role = aws_iam_role.schedule[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
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
    }]
  })
}

resource "aws_scheduler_schedule" "off_hours_page" {
  count = local.off_hours_page ? 1 : 0

  name                         = local.page_name
  description                  = "Point ${var.domain} at the off-hours page at ${var.schedule.off} (${var.schedule.timezone})"
  schedule_expression          = local.schedule_cron.stop
  schedule_expression_timezone = var.schedule.timezone

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = "arn:aws:scheduler:::aws-sdk:route53:changeResourceRecordSets"
    role_arn = aws_iam_role.schedule[0].arn

    # Bounded so a late retry cannot land after the node's boot upsert and put
    # the page up during on-hours.
    retry_policy {
      maximum_event_age_in_seconds = 1800 # inside the shortest off window a schedule allows (1 h)
      maximum_retry_attempts       = 10
    }

    input = jsonencode({
      HostedZoneId = var.zone_id
      ChangeBatch = {
        Changes = [{
          Action = "UPSERT"
          ResourceRecordSet = {
            Name = var.domain
            Type = "A"
            AliasTarget = {
              HostedZoneId         = aws_cloudfront_distribution.off_hours_page[0].hosted_zone_id
              DNSName              = aws_cloudfront_distribution.off_hours_page[0].domain_name
              EvaluateTargetHealth = false
            }
          }
        }]
      }
    })
  }

  depends_on = [aws_iam_role_policy.off_hours_page]
}
