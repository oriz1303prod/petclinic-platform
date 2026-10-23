variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment name (dev or prod)"
  type        = string
  default     = "dev"
}

variable "project" {
  description = "Project name used in resource naming"
  type        = string
  default     = "petclinic"
}

variable "api_allowed_cidrs" {
  description = "CIDR blocks allowed to reach the EKS public API endpoint (your IP /32). Set in terraform.tfvars; 0.0.0.0/0 is rejected."
  type        = list(string)
}

variable "domain_name" {
  description = "DNS zone for the app: a subdomain delegated from Cloudflare (e.g. lab.example.com) or a Route 53 domain. Set in terraform.tfvars"
  type        = string
}

variable "enable_dns" {
  description = "Create the Route 53 zone, ACM certificate and DNS records. false = HTTP-only on the raw ALB DNS name"
  type        = bool
  default     = true
}

variable "create_alb_record" {
  description = "Create the alias record to the ALB. Set true only after the Ingress has created the ALB"
  type        = bool
  default     = false
}
