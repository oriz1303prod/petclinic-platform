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

variable "tags" {
  description = "Additional tags merged onto all resources"
  type        = map(string)
  default     = {}
}

# ---------------------------------------------------------------------------
# Network inputs (from the VPC module)
# ---------------------------------------------------------------------------

variable "subnet_ids" {
  description = "Public subnet IDs for the control plane and worker nodes (all-public design, ADR-0001)"
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) >= 2
    error_message = "EKS requires subnets in at least 2 availability zones."
  }
}

variable "cluster_security_group_id" {
  description = "Security group attached to the EKS control plane ENIs"
  type        = string
}

variable "node_security_group_id" {
  description = "Security group attached to the worker nodes"
  type        = string
}

# ---------------------------------------------------------------------------
# Cluster
# ---------------------------------------------------------------------------

variable "kubernetes_version" {
  description = "Kubernetes version of the control plane (must be in AWS standard support; check: aws eks describe-cluster-versions)"
  type        = string
  default     = "1.35"
}

variable "endpoint_public_access_cidrs" {
  description = "CIDR blocks allowed to reach the public API server endpoint (your own IP /32 or office range). 0.0.0.0/0 is rejected."
  type        = list(string)

  validation {
    condition     = length(var.endpoint_public_access_cidrs) > 0 && alltrue([for c in var.endpoint_public_access_cidrs : can(cidrhost(c, 0)) && c != "0.0.0.0/0"])
    error_message = "Provide at least one valid CIDR and do not use 0.0.0.0/0."
  }
}

variable "cluster_log_types" {
  description = "Control plane log types sent to CloudWatch"
  type        = list(string)
  default     = ["api", "audit", "authenticator"]
}

variable "cluster_log_retention_days" {
  description = "Retention of the control plane CloudWatch log group, in days"
  type        = number
  default     = 30
}

variable "enable_secrets_encryption" {
  description = "Create a KMS key (rotation enabled, ~$1/month) and use it for Kubernetes secrets envelope encryption. Cannot be disabled once enabled on a cluster."
  type        = bool
  default     = true
}

variable "bootstrap_cluster_creator_admin" {
  description = "Grant the principal running terraform apply permanent cluster-admin. Set false (and use access_entries) when the apply principal should not keep admin."
  type        = bool
  default     = true
}

variable "access_entries" {
  description = <<-EOT
    Additional principals granted access to the cluster (EKS access entries), keyed by a short name.
    The principal that runs terraform apply is always granted cluster-admin via the cluster-creator bootstrap.
    Example:
      access_entries = {
        platform-admins = {
          principal_arn = "arn:aws:iam::123456789012:role/platform-admins"
          policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
        }
      }
  EOT
  type = map(object({
    principal_arn     = string
    policy_arn        = optional(string, "arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy")
    access_scope_type = optional(string, "cluster")
    namespaces        = optional(list(string), [])
  }))
  default = {}

  validation {
    condition = alltrue([
      for e in values(var.access_entries) :
      contains(["cluster", "namespace"], e.access_scope_type) && (e.access_scope_type == "cluster" || length(e.namespaces) > 0)
    ])
    error_message = "access_scope_type must be \"cluster\" or \"namespace\", and \"namespace\" scope needs a non-empty namespaces list."
  }
}

# ---------------------------------------------------------------------------
# Managed node group
# ---------------------------------------------------------------------------

variable "node_instance_types" {
  description = "Instance types of the managed node group (ARM/Graviton to match linux/arm64 images)"
  type        = list(string)
  default     = ["t4g.small"]
}

variable "node_ami_type" {
  description = "AMI type of the managed node group"
  type        = string
  default     = "AL2023_ARM_64_STANDARD"
}

variable "node_capacity_type" {
  description = "Capacity type of the managed node group (ON_DEMAND or SPOT)"
  type        = string
  default     = "ON_DEMAND"

  validation {
    condition     = contains(["ON_DEMAND", "SPOT"], var.node_capacity_type)
    error_message = "node_capacity_type must be ON_DEMAND or SPOT."
  }
}

variable "node_min_size" {
  description = "Minimum number of nodes"
  type        = number
  default     = 2
}

variable "node_max_size" {
  description = "Maximum number of nodes"
  type        = number
  default     = 4
}

variable "node_desired_size" {
  description = "Desired number of nodes"
  type        = number
  default     = 2
}

variable "node_disk_size" {
  description = "Root EBS volume size of each node in GB (20 GB fits the 30 GB EBS free tier)"
  type        = number
  default     = 20
}

variable "node_labels" {
  description = "Additional Kubernetes labels applied to the nodes"
  type        = map(string)
  default     = {}
}

variable "node_taints" {
  description = "Kubernetes taints applied to the nodes"
  type = list(object({
    key    = string
    value  = optional(string)
    effect = string
  }))
  default = []

  validation {
    condition     = alltrue([for t in var.node_taints : contains(["NO_SCHEDULE", "NO_EXECUTE", "PREFER_NO_SCHEDULE"], t.effect)])
    error_message = "Taint effect must be NO_SCHEDULE, NO_EXECUTE or PREFER_NO_SCHEDULE."
  }
}

# ---------------------------------------------------------------------------
# Managed add-ons (versions pinned, never "latest" - see docs on upgrading)
# ---------------------------------------------------------------------------

variable "addon_versions" {
  description = "Pinned EKS managed add-on versions. Must be compatible with kubernetes_version."
  type = object({
    coredns            = string
    kube_proxy         = string
    vpc_cni            = string
    aws_ebs_csi_driver = string
  })
  default = {
    coredns            = "v1.13.2-eksbuild.51"
    kube_proxy         = "v1.35.3-eksbuild.52"
    vpc_cni            = "v1.22.4-eksbuild.3"
    aws_ebs_csi_driver = "v1.67.0-eksbuild.1"
  }
}

variable "addon_resolve_conflicts" {
  description = "Conflict strategy when an add-on is created or updated (OVERWRITE for initial setup)"
  type        = string
  default     = "OVERWRITE"

  validation {
    condition     = contains(["NONE", "OVERWRITE", "PRESERVE"], var.addon_resolve_conflicts)
    error_message = "addon_resolve_conflicts must be NONE, OVERWRITE or PRESERVE."
  }
}
