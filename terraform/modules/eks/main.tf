data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  name = "${var.project}-${var.environment}"

  common_tags = merge(
    {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
      Component   = "eks"
    },
    var.tags,
  )

  oidc_host = replace(aws_iam_openid_connect_provider.this.url, "https://", "")
}

# ---------------------------------------------------------------------------
# Cluster IAM role
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "cluster_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster" {
  name               = "${local.name}-eks-cluster-role"
  assume_role_policy = data.aws_iam_policy_document.cluster_assume.json

  tags = merge(local.common_tags, { Name = "${local.name}-eks-cluster-role" })
}

resource "aws_iam_role_policy_attachment" "cluster" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSClusterPolicy"
}

# ---------------------------------------------------------------------------
# Control plane
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "cluster" {
  name              = "/aws/eks/${local.name}/cluster"
  retention_in_days = var.cluster_log_retention_days

  tags = merge(local.common_tags, { Name = "${local.name}-eks-logs" })
}

resource "aws_kms_key" "secrets" {
  count = var.enable_secrets_encryption ? 1 : 0

  description             = "${local.name} EKS Kubernetes secrets envelope encryption"
  enable_key_rotation     = true
  deletion_window_in_days = 7

  tags = merge(local.common_tags, { Name = "${local.name}-eks-secrets" })
}

resource "aws_kms_alias" "secrets" {
  count = var.enable_secrets_encryption ? 1 : 0

  name          = "alias/${local.name}-eks-secrets"
  target_key_id = aws_kms_key.secrets[0].key_id
}

resource "aws_eks_cluster" "this" {
  name     = local.name
  version  = var.kubernetes_version
  role_arn = aws_iam_role.cluster.arn

  enabled_cluster_log_types = var.cluster_log_types

  vpc_config {
    subnet_ids              = var.subnet_ids
    security_group_ids      = [var.cluster_security_group_id]
    endpoint_public_access  = true
    endpoint_private_access = true
    public_access_cidrs     = var.endpoint_public_access_cidrs
  }

  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = var.bootstrap_cluster_creator_admin
  }

  # Without this, the control plane moves to paid extended support when standard support ends
  upgrade_policy {
    support_type = "STANDARD"
  }

  dynamic "encryption_config" {
    for_each = var.enable_secrets_encryption ? [1] : []

    content {
      resources = ["secrets"]

      provider {
        key_arn = aws_kms_key.secrets[0].arn
      }
    }
  }

  tags = merge(local.common_tags, { Name = local.name })

  depends_on = [
    aws_iam_role_policy_attachment.cluster,
    aws_cloudwatch_log_group.cluster,
  ]
}

# ---------------------------------------------------------------------------
# OIDC provider (IRSA)
# ---------------------------------------------------------------------------

# Thumbprint of the top CA in the issuer's TLS chain. AWS validates EKS issuers
# with its trusted root CAs and ignores it, but it is kept for completeness.
data "tls_certificate" "oidc" {
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "this" {
  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.oidc.certificates[length(data.tls_certificate.oidc.certificates) - 1].sha1_fingerprint]

  tags = merge(local.common_tags, { Name = "${local.name}-eks-oidc" })
}

# ---------------------------------------------------------------------------
# kubectl access (EKS access entries)
# The principal that creates the cluster is bootstrapped as cluster-admin
# (bootstrap_cluster_creator_admin_permissions). Extra principals go through
# var.access_entries.
# ---------------------------------------------------------------------------

resource "aws_eks_access_entry" "this" {
  for_each = var.access_entries

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value.principal_arn
  type          = "STANDARD"

  tags = merge(local.common_tags, { Name = "${local.name}-access-${each.key}" })
}

resource "aws_eks_access_policy_association" "this" {
  for_each = var.access_entries

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = aws_eks_access_entry.this[each.key].principal_arn
  policy_arn    = each.value.policy_arn

  access_scope {
    type       = each.value.access_scope_type
    namespaces = each.value.access_scope_type == "namespace" ? each.value.namespaces : null
  }
}

# ---------------------------------------------------------------------------
# Node IAM role
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "node_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  name               = "${local.name}-eks-node-role"
  assume_role_policy = data.aws_iam_policy_document.node_assume.json

  tags = merge(local.common_tags, { Name = "${local.name}-eks-node-role" })
}

resource "aws_iam_role_policy_attachment" "node" {
  for_each = toset([
    "AmazonEKSWorkerNodePolicy",
    "AmazonEKS_CNI_Policy",
    "AmazonEC2ContainerRegistryReadOnly",
  ])

  role       = aws_iam_role.node.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/${each.value}"
}

# ---------------------------------------------------------------------------
# Managed node group (launch template attaches the node SG, encrypts the root
# volume and enforces IMDSv2)
# ---------------------------------------------------------------------------

resource "aws_launch_template" "node" {
  name_prefix            = "${local.name}-node-"
  update_default_version = true
  vpc_security_group_ids = [var.node_security_group_id]

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size           = var.node_disk_size
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  tag_specifications {
    resource_type = "instance"
    tags          = merge(local.common_tags, { Name = "${local.name}-node" })
  }

  tag_specifications {
    resource_type = "volume"
    tags          = merge(local.common_tags, { Name = "${local.name}-node-root" })
  }

  tags = merge(local.common_tags, { Name = "${local.name}-node-lt" })
}

resource "aws_eks_node_group" "this" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${local.name}-nodes"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.subnet_ids

  instance_types = var.node_instance_types
  ami_type       = var.node_ami_type
  capacity_type  = var.node_capacity_type

  scaling_config {
    min_size     = var.node_min_size
    max_size     = var.node_max_size
    desired_size = var.node_desired_size
  }

  update_config {
    max_unavailable = 1
  }

  node_repair_config {
    enabled = true
  }

  launch_template {
    id      = aws_launch_template.node.id
    version = aws_launch_template.node.latest_version
  }

  labels = merge(
    {
      environment  = var.environment
      "managed-by" = "terraform"
    },
    var.node_labels,
  )

  dynamic "taint" {
    for_each = var.node_taints

    content {
      key    = taint.value.key
      value  = taint.value.value
      effect = taint.value.effect
    }
  }

  tags = merge(local.common_tags, { Name = "${local.name}-nodes" })

  # The CNI and kube-proxy add-ons must exist before nodes join
  depends_on = [
    aws_iam_role_policy_attachment.node,
    aws_eks_addon.vpc_cni,
    aws_eks_addon.kube_proxy,
  ]
}

# ---------------------------------------------------------------------------
# IRSA role for the EBS CSI driver
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "ebs_csi_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.this.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:sub"
      values   = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ebs_csi" {
  name               = "${local.name}-ebs-csi-role"
  assume_role_policy = data.aws_iam_policy_document.ebs_csi_assume.json

  tags = merge(local.common_tags, { Name = "${local.name}-ebs-csi-role" })
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# ---------------------------------------------------------------------------
# Managed add-ons (pinned versions)
# CoreDNS and the EBS CSI controller are pods, so they need the nodes first.
# vpc-cni and kube-proxy are DaemonSets and can be created with the cluster.
# ---------------------------------------------------------------------------

resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "vpc-cni"
  addon_version               = var.addon_versions.vpc_cni
  resolve_conflicts_on_create = var.addon_resolve_conflicts
  resolve_conflicts_on_update = var.addon_resolve_conflicts

  tags = merge(local.common_tags, { Name = "${local.name}-addon-vpc-cni" })
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "kube-proxy"
  addon_version               = var.addon_versions.kube_proxy
  resolve_conflicts_on_create = var.addon_resolve_conflicts
  resolve_conflicts_on_update = var.addon_resolve_conflicts

  tags = merge(local.common_tags, { Name = "${local.name}-addon-kube-proxy" })
}

resource "aws_eks_addon" "coredns" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "coredns"
  addon_version               = var.addon_versions.coredns
  resolve_conflicts_on_create = var.addon_resolve_conflicts
  resolve_conflicts_on_update = var.addon_resolve_conflicts

  tags = merge(local.common_tags, { Name = "${local.name}-addon-coredns" })

  depends_on = [aws_eks_node_group.this]
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "aws-ebs-csi-driver"
  addon_version               = var.addon_versions.aws_ebs_csi_driver
  service_account_role_arn    = aws_iam_role.ebs_csi.arn
  resolve_conflicts_on_create = var.addon_resolve_conflicts
  resolve_conflicts_on_update = var.addon_resolve_conflicts

  tags = merge(local.common_tags, { Name = "${local.name}-addon-ebs-csi" })

  depends_on = [
    aws_eks_node_group.this,
    aws_iam_role_policy_attachment.ebs_csi,
  ]
}
