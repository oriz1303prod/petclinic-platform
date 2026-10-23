output "zone_id" {
  description = "Route 53 hosted zone ID (null when enable_dns is false)"
  value       = one(aws_route53_zone.this[*].zone_id)
}

output "name_servers" {
  description = "Name servers of the hosted zone; add them as NS records in the parent DNS provider (Cloudflare) to delegate the subdomain"
  value       = one(aws_route53_zone.this[*].name_servers)
}

output "certificate_arn" {
  description = "ARN of the validated ACM wildcard certificate (null when enable_dns is false)"
  value       = one(aws_acm_certificate_validation.this[*].certificate_arn)
}

output "app_fqdn" {
  description = "Fully qualified hostname of the application"
  value       = var.enable_dns ? local.app_fqdn : null
}

output "alb_name" {
  description = "Name the Ingress must give the ALB (load-balancer-name annotation)"
  value       = local.alb_name
}

output "lb_controller_role_arn" {
  description = "IRSA role ARN for the AWS Load Balancer Controller service account"
  value       = aws_iam_role.lb_controller.arn
}
