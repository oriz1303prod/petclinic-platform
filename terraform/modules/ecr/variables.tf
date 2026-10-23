variable "project" {
  description = "Project name used in resource naming"
  type        = string
  default     = "petclinic"
}

variable "environment" {
  description = "Environment name (dev or prod); repositories are created under the petclinic-{environment}/ namespace"
  type        = string

  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "environment must be either \"dev\" or \"prod\"."
  }
}

variable "service_names" {
  description = "Service names to create one ECR repository for (e.g. config-server, api-gateway)"
  type        = list(string)

  validation {
    condition     = length(var.service_names) > 0 && length(var.service_names) == length(distinct(var.service_names))
    error_message = "service_names must be a non-empty list without duplicates."
  }

  validation {
    condition     = alltrue([for n in var.service_names : can(regex("^[a-z0-9]+([._-][a-z0-9]+)*$", n))])
    error_message = "Each service name must be lowercase letters and digits, optionally separated by '.', '_' or '-'."
  }
}

variable "image_tag_mutability" {
  description = "Tag mutability for all repositories: MUTABLE for dev, IMMUTABLE for prod"
  type        = string
  default     = "MUTABLE"

  validation {
    condition     = contains(["MUTABLE", "IMMUTABLE"], var.image_tag_mutability)
    error_message = "image_tag_mutability must be either \"MUTABLE\" or \"IMMUTABLE\"."
  }
}

variable "max_image_count" {
  description = "Number of tagged images to keep per repository; older tagged images expire"
  type        = number
  default     = 10

  validation {
    condition     = var.max_image_count >= 1
    error_message = "max_image_count must be at least 1."
  }
}

variable "untagged_expiry_days" {
  description = "Days after push when untagged images expire"
  type        = number
  default     = 7

  validation {
    condition     = var.untagged_expiry_days >= 1
    error_message = "untagged_expiry_days must be at least 1."
  }
}

variable "tags" {
  description = "Additional tags merged onto every resource"
  type        = map(string)
  default     = {}
}
