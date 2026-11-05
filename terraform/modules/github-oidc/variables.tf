variable "project" {
  description = "Project name used in resource naming"
  type        = string
  default     = "petclinic"
}

variable "aws_region" {
  description = "AWS region for ECR resource ARNs"
  type        = string
  default     = "us-east-1"
}

variable "github_username" {
  description = "GitHub username or org that owns the application repository"
  type        = string
}

variable "github_repo" {
  description = "GitHub repository name for the application code"
  type        = string
  default     = "spring-petclinic-microservices"
}

variable "tags" {
  description = "Additional tags to merge with default tags"
  type        = map(string)
  default     = {}
}
