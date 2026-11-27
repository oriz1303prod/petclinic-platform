variable "project" {
  description = "Project name used in resource naming and tags"
  type        = string
  default     = "petclinic"
}

variable "environment" {
  description = "Environment name (dev or prod)"
  type        = string

  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "environment must be \"dev\" or \"prod\"."
  }
}

variable "cluster_name" {
  description = "EKS cluster name Karpenter provisions nodes for"
  type        = string
}

variable "oidc_provider_arn" {
  description = "ARN of the cluster's IAM OIDC provider (module.eks.oidc_provider_arn), used as the IRSA trust principal"
  type        = string
}

variable "oidc_provider_url" {
  description = "URL of the cluster's IAM OIDC provider without https:// (module.eks.oidc_provider_url), used in the IRSA trust conditions"
  type        = string
}

variable "node_role_arn" {
  description = "ARN of the node IAM role (module.eks.node_role_arn). Karpenter-launched nodes use it through the instance profile this module creates"
  type        = string
}

variable "karpenter_namespace" {
  description = "Namespace of the Karpenter controller ServiceAccount (the IRSA trust is scoped to it)"
  type        = string
  default     = "kube-system"
}

variable "karpenter_service_account" {
  description = "Name of the Karpenter controller ServiceAccount (the IRSA trust is scoped to it)"
  type        = string
  default     = "karpenter"
}

variable "tags" {
  description = "Additional tags merged into the module's default tags"
  type        = map(string)
  default     = {}
}
