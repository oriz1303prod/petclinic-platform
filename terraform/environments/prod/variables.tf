variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment name (dev or prod)"
  type        = string
  default     = "prod"
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

variable "openai_api_key" {
  description = "OpenAI API key stored in Secrets Manager. Set with TF_VAR_openai_api_key or in the git-ignored terraform.tfvars; never commit it"
  type        = string
  sensitive   = true
}

variable "monthly_budget_usd" {
  description = "Monthly AWS Budget limit in USD; alerts fire at 50%, 80% and 100% of actual spend"
  type        = number
  default     = 10
}

variable "budget_alert_email" {
  description = "Email address that receives AWS Budget alerts. Set in the git-ignored terraform.tfvars"
  type        = string

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.budget_alert_email))
    error_message = "budget_alert_email must be a valid email address."
  }
}
