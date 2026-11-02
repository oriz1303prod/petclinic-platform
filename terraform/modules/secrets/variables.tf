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

variable "openai_api_key" {
  description = "OpenAI API key stored in petclinic/{env}/openai-api-key. Pass it with TF_VAR_openai_api_key or a git-ignored tfvars file, never in code"
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.openai_api_key) > 0
    error_message = "openai_api_key must not be empty (the genai-service reads it from the synced Kubernetes Secret)."
  }
}

variable "enable_config_server_git_secrets" {
  description = "Create the optional config-server Git credentials secrets (git-username and git-password). Needs both values below"
  type        = bool
  default     = false
}

variable "config_server_git_username" {
  description = "Git username for the Config Server repository (used only when enable_config_server_git_secrets is true)"
  type        = string
  default     = null
  sensitive   = true
}

variable "config_server_git_password" {
  description = "Git password or token for the Config Server repository (used only when enable_config_server_git_secrets is true)"
  type        = string
  default     = null
  sensitive   = true
}

variable "recovery_window_in_days" {
  description = "Days Secrets Manager keeps a deleted secret before removing it. 0 deletes immediately (dev), 7 to 30 for prod"
  type        = number
  default     = 7

  validation {
    condition     = var.recovery_window_in_days == 0 || (var.recovery_window_in_days >= 7 && var.recovery_window_in_days <= 30)
    error_message = "recovery_window_in_days must be 0 or between 7 and 30."
  }
}

variable "oidc_provider_arn" {
  description = "ARN of the EKS IAM OIDC provider (IRSA)"
  type        = string
}

variable "oidc_provider_url" {
  description = "URL of the EKS IAM OIDC provider without https://"
  type        = string
}

variable "eso_namespace" {
  description = "Namespace External Secrets Operator runs in"
  type        = string
  default     = "external-secrets"
}

variable "eso_service_account" {
  description = "ServiceAccount referenced by the ClusterSecretStore (jwt auth); the IRSA role trusts only this account"
  type        = string
  default     = "external-secrets-sa"
}

variable "tags" {
  description = "Additional tags for all resources"
  type        = map(string)
  default     = {}
}
