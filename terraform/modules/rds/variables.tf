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

variable "subnet_ids" {
  description = "Subnet IDs for the DB subnet group (at least two, in different AZs)"
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) >= 2
    error_message = "A DB subnet group needs subnets in at least two availability zones."
  }
}

variable "security_group_id" {
  description = "ID of the RDS security group (should only allow 3306 from the EKS node SG)"
  type        = string
}

variable "engine_version" {
  description = "MySQL engine version; \"8.4\" lets RDS pick the latest 8.4 minor"
  type        = string
  default     = "8.4"
}

variable "instance_class" {
  description = "RDS instance class (db.t4g.micro is free tier eligible and Graviton-based)"
  type        = string
  default     = "db.t4g.micro"
}

variable "allocated_storage" {
  description = "Initial storage in GB"
  type        = number
  default     = 20
}

variable "max_allocated_storage" {
  description = "Upper limit in GB for storage autoscaling; autoscaling is only enabled when this is greater than allocated_storage"
  type        = number
  default     = 20
}

variable "multi_az" {
  description = "Deploy a standby in a second AZ. false for cost optimization; enable for real production workloads"
  type        = bool
  default     = false
}

variable "backup_retention_period" {
  description = "Days to keep automated backups"
  type        = number
  default     = 7

  validation {
    condition     = var.backup_retention_period >= 1 && var.backup_retention_period <= 35
    error_message = "backup_retention_period must be between 1 and 35 days."
  }
}

variable "skip_final_snapshot" {
  description = "Skip the final snapshot when the instance is deleted (dev sets true explicitly)"
  type        = bool
  default     = false
}

variable "deletion_protection" {
  description = "Prevent the instance from being deleted"
  type        = bool
  default     = false
}

variable "database_name" {
  description = "Name of the single shared database used by customers, visits and vets services"
  type        = string
  default     = "petclinic"
}

variable "master_username" {
  description = "Master username of the instance"
  type        = string
  default     = "petclinic"
}

variable "secret_recovery_window_in_days" {
  description = "Days Secrets Manager keeps the secret after deletion (0 = delete immediately, otherwise 7-30)"
  type        = number
  default     = 7

  validation {
    condition     = var.secret_recovery_window_in_days == 0 || (var.secret_recovery_window_in_days >= 7 && var.secret_recovery_window_in_days <= 30)
    error_message = "secret_recovery_window_in_days must be 0 or between 7 and 30."
  }
}

variable "log_retention_in_days" {
  description = "Retention in days for the RDS error and slowquery CloudWatch log groups"
  type        = number
  default     = 7
}

variable "tags" {
  description = "Additional tags for all resources"
  type        = map(string)
  default     = {}
}
