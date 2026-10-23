variable "project" {
  description = "Project name used in resource naming"
  type        = string
  default     = "petclinic"
}

variable "environment" {
  description = "Environment name (dev or prod)"
  type        = string

  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "environment must be either \"dev\" or \"prod\"."
  }
}

variable "domain_name" {
  description = "DNS name of the hosted zone. Use a subdomain delegated from Cloudflare (e.g. lab.example.com) or a domain registered in Route 53"
  type        = string

  validation {
    condition     = can(regex("^([a-z0-9]([a-z0-9-]*[a-z0-9])?\\.)+[a-z]{2,}$", var.domain_name))
    error_message = "domain_name must be a lowercase DNS name such as lab.example.com (no trailing dot)."
  }
}

variable "enable_dns" {
  description = "Create the hosted zone, ACM certificate and DNS records. false = HTTP-only setup on the raw ALB DNS name (the LB controller IAM role is still created)"
  type        = bool
  default     = true
}

variable "app_hostname" {
  description = "Host label of the application record inside the zone (petclinic-dev gives petclinic-dev.<domain_name>)"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?$", var.app_hostname))
    error_message = "app_hostname must be a single lowercase DNS label."
  }
}

variable "create_alb_record" {
  description = "Create the alias record to the ALB. Set true only after the Ingress has created the ALB (looked up by alb_name)"
  type        = bool
  default     = false
}

variable "oidc_provider_arn" {
  description = "ARN of the EKS IAM OIDC provider (IRSA)"
  type        = string
}

variable "oidc_provider_url" {
  description = "URL of the EKS IAM OIDC provider without https://"
  type        = string
}

variable "lb_controller_namespace" {
  description = "Namespace the AWS Load Balancer Controller runs in"
  type        = string
  default     = "kube-system"
}

variable "lb_controller_service_account" {
  description = "ServiceAccount name of the AWS Load Balancer Controller"
  type        = string
  default     = "aws-load-balancer-controller"
}

variable "tags" {
  description = "Additional tags for all resources"
  type        = map(string)
  default     = {}
}
