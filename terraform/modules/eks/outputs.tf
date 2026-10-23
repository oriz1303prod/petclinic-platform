output "cluster_name" {
  description = "EKS cluster name"
  value       = aws_eks_cluster.this.name
}

output "cluster_arn" {
  description = "EKS cluster ARN"
  value       = aws_eks_cluster.this.arn
}

output "cluster_endpoint" {
  description = "EKS API server endpoint"
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_ca_certificate" {
  description = "Base64-encoded certificate authority data of the cluster"
  value       = aws_eks_cluster.this.certificate_authority[0].data
  sensitive   = true
}

output "cluster_version" {
  description = "Kubernetes version of the control plane"
  value       = aws_eks_cluster.this.version
}

output "oidc_provider_arn" {
  description = "ARN of the IAM OIDC provider (IRSA)"
  value       = aws_iam_openid_connect_provider.this.arn
}

output "oidc_provider_url" {
  description = "URL of the IAM OIDC provider, without the https:// prefix (used in IRSA trust policy conditions)"
  value       = local.oidc_host
}

output "node_group_name" {
  description = "Managed node group name"
  value       = aws_eks_node_group.this.node_group_name
}

output "node_role_arn" {
  description = "IAM role ARN of the worker nodes"
  value       = aws_iam_role.node.arn
}

output "ebs_csi_role_arn" {
  description = "IRSA role ARN of the EBS CSI driver"
  value       = aws_iam_role.ebs_csi.arn
}

output "kubeconfig_command" {
  description = "Command that adds this cluster to your local kubeconfig"
  value       = "aws eks update-kubeconfig --name ${aws_eks_cluster.this.name} --region ${data.aws_region.current.name}"
}
