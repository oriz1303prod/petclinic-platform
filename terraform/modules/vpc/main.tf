locals {
  name = "${var.project}-${var.environment}"

  common_tags = merge(
    {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
      Component   = "networking"
    },
    var.tags,
  )

  # EKS node ports used by the ALB target groups
  nodeport_from = 30000
  nodeport_to   = 32767
}

# ---------------------------------------------------------------------------
# VPC, subnets, internet gateway, routing (all-public design, no NAT — ADR-0001)
# ---------------------------------------------------------------------------

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.common_tags, { Name = "${local.name}-vpc" })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(local.common_tags, { Name = "${local.name}-igw" })
}

resource "aws_subnet" "public" {
  count = length(var.public_subnet_cidrs)

  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = true

  lifecycle {
    precondition {
      condition     = length(var.public_subnet_cidrs) == length(var.availability_zones)
      error_message = "public_subnet_cidrs and availability_zones must have the same number of entries."
    }
  }

  tags = merge(local.common_tags, {
    Name                                  = "${local.name}-public-${var.availability_zones[count.index]}"
    "kubernetes.io/cluster/${local.name}" = "shared"
    "kubernetes.io/role/elb"              = "1"
  })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  tags = merge(local.common_tags, { Name = "${local.name}-public-rt" })
}

resource "aws_route" "internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  count = length(aws_subnet.public)

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# ---------------------------------------------------------------------------
# Security groups (primary access-control boundary)
# Rules are separate resources to avoid circular references between SGs.
# ---------------------------------------------------------------------------

resource "aws_security_group" "eks_cluster" {
  name        = "${local.name}-eks-cluster-sg"
  description = "EKS control plane security group"
  vpc_id      = aws_vpc.this.id

  tags = merge(local.common_tags, { Name = "${local.name}-eks-cluster-sg" })
}

resource "aws_security_group" "eks_node" {
  name        = "${local.name}-eks-node-sg"
  description = "EKS worker node security group"
  vpc_id      = aws_vpc.this.id

  tags = merge(local.common_tags, { Name = "${local.name}-eks-node-sg" })
}

resource "aws_security_group" "rds" {
  name        = "${local.name}-rds-sg"
  description = "RDS MySQL security group (access from EKS nodes only)"
  vpc_id      = aws_vpc.this.id

  tags = merge(local.common_tags, { Name = "${local.name}-rds-sg" })
}

resource "aws_security_group" "alb" {
  name        = "${local.name}-alb-sg"
  description = "Public ALB security group"
  vpc_id      = aws_vpc.this.id

  tags = merge(local.common_tags, { Name = "${local.name}-alb-sg" })
}

# Empty default SG: strips the allow-all rules so nothing can accidentally use it
resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(local.common_tags, { Name = "${local.name}-default-sg" })
}

# --- EKS cluster SG ---

resource "aws_vpc_security_group_ingress_rule" "cluster_api_from_nodes" {
  security_group_id            = aws_security_group.eks_cluster.id
  description                  = "API server access from EKS nodes"
  referenced_security_group_id = aws_security_group.eks_node.id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
}

resource "aws_vpc_security_group_egress_rule" "cluster_all_out" {
  security_group_id = aws_security_group.eks_cluster.id
  description       = "All outbound"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# --- EKS node SG ---

resource "aws_vpc_security_group_ingress_rule" "node_all_from_cluster" {
  security_group_id            = aws_security_group.eks_node.id
  description                  = "All traffic from EKS cluster SG"
  referenced_security_group_id = aws_security_group.eks_cluster.id
  ip_protocol                  = "-1"
}

resource "aws_vpc_security_group_ingress_rule" "node_all_from_self" {
  security_group_id            = aws_security_group.eks_node.id
  description                  = "Inter-node communication"
  referenced_security_group_id = aws_security_group.eks_node.id
  ip_protocol                  = "-1"
}

resource "aws_vpc_security_group_ingress_rule" "node_kubelet_from_cluster" {
  security_group_id            = aws_security_group.eks_node.id
  description                  = "Kubelet API from EKS cluster SG"
  referenced_security_group_id = aws_security_group.eks_cluster.id
  ip_protocol                  = "tcp"
  from_port                    = 10250
  to_port                      = 10250
}

resource "aws_vpc_security_group_ingress_rule" "node_nodeport_from_alb" {
  security_group_id            = aws_security_group.eks_node.id
  description                  = "NodePort services from ALB SG"
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = local.nodeport_from
  to_port                      = local.nodeport_to
}

resource "aws_vpc_security_group_ingress_rule" "node_health_from_alb" {
  security_group_id            = aws_security_group.eks_node.id
  description                  = "ALB health checks to pods (port 8080)"
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
}

resource "aws_vpc_security_group_egress_rule" "node_all_out" {
  security_group_id = aws_security_group.eks_node.id
  description       = "All outbound (ECR, S3, Secrets Manager via IGW)"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# --- RDS SG (ingress from EKS nodes only, no egress) ---

resource "aws_vpc_security_group_ingress_rule" "rds_mysql_from_nodes" {
  security_group_id            = aws_security_group.rds.id
  description                  = "MySQL from EKS nodes"
  referenced_security_group_id = aws_security_group.eks_node.id
  ip_protocol                  = "tcp"
  from_port                    = 3306
  to_port                      = 3306
}

# --- ALB SG ---

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTP from internet"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTPS from internet"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_security_group_egress_rule" "alb_nodeport_to_nodes" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Target group traffic to EKS nodes"
  referenced_security_group_id = aws_security_group.eks_node.id
  ip_protocol                  = "tcp"
  from_port                    = local.nodeport_from
  to_port                      = local.nodeport_to
}

resource "aws_vpc_security_group_egress_rule" "alb_health_to_nodes" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Health checks to EKS nodes"
  referenced_security_group_id = aws_security_group.eks_node.id
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
}
