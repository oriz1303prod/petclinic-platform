output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "public_subnet_ids" {
  description = "Public subnet IDs"
  value       = module.vpc.public_subnet_ids
}

output "eks_cluster_sg_id" {
  description = "EKS cluster security group ID"
  value       = module.vpc.eks_cluster_sg_id
}

output "eks_node_sg_id" {
  description = "EKS node security group ID"
  value       = module.vpc.eks_node_sg_id
}

output "rds_sg_id" {
  description = "RDS security group ID"
  value       = module.vpc.rds_sg_id
}

output "alb_sg_id" {
  description = "ALB security group ID"
  value       = module.vpc.alb_sg_id
}

output "eks_cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "eks_cluster_endpoint" {
  description = "EKS API server endpoint"
  value       = module.eks.cluster_endpoint
}

output "eks_cluster_ca_certificate" {
  description = "Base64-encoded certificate authority data of the cluster"
  value       = module.eks.cluster_ca_certificate
  sensitive   = true
}

output "eks_oidc_provider_arn" {
  description = "ARN of the EKS IAM OIDC provider (IRSA)"
  value       = module.eks.oidc_provider_arn
}

output "eks_oidc_provider_url" {
  description = "URL of the EKS IAM OIDC provider, without https://"
  value       = module.eks.oidc_provider_url
}

output "eks_node_group_name" {
  description = "EKS managed node group name"
  value       = module.eks.node_group_name
}

output "eks_node_role_arn" {
  description = "IAM role ARN of the EKS worker nodes"
  value       = module.eks.node_role_arn
}

output "eks_kubeconfig_command" {
  description = "Command that adds the EKS cluster to your local kubeconfig"
  value       = module.eks.kubeconfig_command
}

output "ecr_repository_urls" {
  description = "Map of service name to ECR repository URL"
  value       = module.ecr.repository_urls
}

output "ecr_repository_arns" {
  description = "Map of service name to ECR repository ARN"
  value       = module.ecr.repository_arns
}

output "rds_endpoint" {
  description = "RDS MySQL endpoint hostname"
  value       = module.rds.endpoint
}

output "rds_port" {
  description = "RDS MySQL port"
  value       = module.rds.port
}

output "rds_db_instance_id" {
  description = "RDS instance ID"
  value       = module.rds.db_instance_id
}

output "rds_secret_arn" {
  description = "Secrets Manager ARN of the RDS credentials (for External Secrets Operator)"
  value       = module.rds.secret_arn
}

output "eso_role_arn" {
  description = "IRSA role ARN for the External Secrets Operator ServiceAccount (external-secrets-sa)"
  value       = module.secrets.eso_role_arn
}

output "openai_secret_arn" {
  description = "Secrets Manager ARN of the OpenAI API key secret"
  value       = module.secrets.openai_secret_arn
}
