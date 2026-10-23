locals {
  name = "${var.project}-${var.environment}"

  # Fixed name set on the Ingress (load-balancer-name annotation) so Terraform can find the ALB
  alb_name = "${local.name}-alb"
  app_fqdn = "${var.app_hostname}.${var.domain_name}"

  # Mandatory tags come last so callers cannot override them
  common_tags = merge(
    var.tags,
    {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
      Component   = "dns"
    },
  )
}

# --- Route 53 hosted zone ---
# With a Cloudflare-registered domain this is a delegated subdomain: after the first apply,
# add the name_servers output as NS records in Cloudflare (see docs/dns-cloudflare-delegation.md).

resource "aws_route53_zone" "this" {
  count = var.enable_dns ? 1 : 0

  name    = var.domain_name
  comment = "${local.name} hosted zone"

  tags = merge(local.common_tags, { Name = "${local.name}-zone" })

  # A new zone gets new name servers, which would silently break the Cloudflare delegation
  lifecycle {
    prevent_destroy = true
  }
}

# --- ACM wildcard certificate (us-east-1, same region as the ALB) ---

resource "aws_acm_certificate" "this" {
  count = var.enable_dns ? 1 : 0

  domain_name       = "*.${var.domain_name}"
  validation_method = "DNS"

  tags = merge(local.common_tags, { Name = "${local.name}-cert" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "cert_validation" {
  for_each = var.enable_dns ? {
    for o in aws_acm_certificate.this[0].domain_validation_options : o.domain_name => {
      name   = o.resource_record_name
      type   = o.resource_record_type
      record = o.resource_record_value
    }
  } : {}

  zone_id         = aws_route53_zone.this[0].zone_id
  name            = each.value.name
  type            = each.value.type
  ttl             = 60
  records         = [each.value.record]
  allow_overwrite = true
}

# Waits until ACM sees the validation record. This only succeeds once the zone is delegated
# (NS records in the parent DNS provider); until then the apply waits and then times out.
resource "aws_acm_certificate_validation" "this" {
  count = var.enable_dns ? 1 : 0

  certificate_arn         = aws_acm_certificate.this[0].arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]

  # Fail in 30 minutes instead of the 75 minute default when the delegation is missing
  timeouts {
    create = "30m"
  }
}

check "alb_record_needs_dns" {
  assert {
    condition     = var.enable_dns || !var.create_alb_record
    error_message = "create_alb_record has no effect when enable_dns is false."
  }
}

# --- Alias record to the ALB created by the AWS Load Balancer Controller ---

data "aws_lb" "app" {
  count = var.enable_dns && var.create_alb_record ? 1 : 0

  name = local.alb_name
}

resource "aws_route53_record" "app" {
  count = var.enable_dns && var.create_alb_record ? 1 : 0

  zone_id = aws_route53_zone.this[0].zone_id
  name    = local.app_fqdn
  type    = "A"

  alias {
    name                   = data.aws_lb.app[0].dns_name
    zone_id                = data.aws_lb.app[0].zone_id
    evaluate_target_health = true
  }
}

# --- AWS Load Balancer Controller IRSA role (always created) ---

resource "aws_iam_policy" "lb_controller" {
  name        = "${local.name}-lb-controller-policy"
  description = "AWS Load Balancer Controller permissions (official policy, controller v3.6.1)"
  policy      = file("${path.module}/lb-controller-iam-policy.json")

  tags = merge(local.common_tags, { Name = "${local.name}-lb-controller-policy" })
}

data "aws_iam_policy_document" "lb_controller_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:sub"
      values   = ["system:serviceaccount:${var.lb_controller_namespace}:${var.lb_controller_service_account}"]
    }
  }
}

resource "aws_iam_role" "lb_controller" {
  name               = "${local.name}-lb-controller-role"
  description        = "IRSA role for the AWS Load Balancer Controller"
  assume_role_policy = data.aws_iam_policy_document.lb_controller_assume.json

  tags = merge(local.common_tags, { Name = "${local.name}-lb-controller-role" })
}

resource "aws_iam_role_policy_attachment" "lb_controller" {
  role       = aws_iam_role.lb_controller.name
  policy_arn = aws_iam_policy.lb_controller.arn
}
