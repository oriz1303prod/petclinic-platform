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

variable "github_owner_id" {
  description = "Numeric GitHub owner ID (visible in OIDC sub claim). Find via: curl -s https://api.github.com/users/USERNAME | jq .id"
  type        = string
}

variable "github_repo_id" {
  description = "Numeric GitHub repo ID (visible in OIDC sub claim). Find via: curl -s https://api.github.com/repos/OWNER/REPO | jq .id"
  type        = string
}

variable "tags" {
  description = "Additional tags to merge with default tags"
  type        = map(string)
  default     = {}
}
