# karpenter module
#
# AWS-side prerequisites for Karpenter (PETPLAT-73, technical spec: "Karpenter Node Autoscaling"):
#   - IRSA role for the controller (ServiceAccount kube-system/karpenter)
#   - instance profile for Karpenter-launched nodes (wraps the existing node role)
#   - SQS interruption queue plus the EventBridge rules that feed it
#
# The controller, NodePool and EC2NodeClass are installed from Kubernetes (Helm / ArgoCD), not here.

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

locals {
  name       = "${var.project}-${var.environment}"
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.name
  partition  = data.aws_partition.current.partition

  # An IAM role ARN is arn:aws:iam::<account>:role[/path]/<name>; the profile needs the bare name
  node_role_name = element(split("/", var.node_role_arn), length(split("/", var.node_role_arn)) - 1)

  cluster_arn = "arn:${local.partition}:eks:${local.region}:${local.account_id}:cluster/${var.cluster_name}"

  common_tags = merge(
    {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
      Component   = "karpenter"
    },
    var.tags,
  )

  # EventBridge rules that feed the interruption queue (the 4 events Karpenter handles)
  interruption_events = {
    spot-interruption = {
      description = "EC2 Spot interruption warning (2-minute notice)"
      pattern = {
        source        = ["aws.ec2"]
        "detail-type" = ["EC2 Spot Instance Interruption Warning"]
      }
    }
    rebalance-recommendation = {
      description = "EC2 instance rebalance recommendation"
      pattern = {
        source        = ["aws.ec2"]
        "detail-type" = ["EC2 Instance Rebalance Recommendation"]
      }
    }
    instance-state-change = {
      description = "EC2 instance state-change notification"
      pattern = {
        source        = ["aws.ec2"]
        "detail-type" = ["EC2 Instance State-change Notification"]
      }
    }
    scheduled-change = {
      description = "AWS Health scheduled change events for EC2"
      pattern = {
        source        = ["aws.health"]
        "detail-type" = ["AWS Health Event"]
        detail        = { service = ["EC2"] }
      }
    }
  }
}

# ---------------------------------------------------------------------------
# Instance profile for Karpenter-launched nodes
# ---------------------------------------------------------------------------
# The EC2NodeClass references this exact name: petclinic-{env}-karpenter-node-profile.
# It wraps the node role the managed node group already uses, so Karpenter nodes get the same
# permissions and are already allowed to join the cluster.

resource "aws_iam_instance_profile" "node" {
  name = "${local.name}-karpenter-node-profile"
  role = local.node_role_name

  tags = merge(local.common_tags, { Name = "${local.name}-karpenter-node-profile" })
}

# ---------------------------------------------------------------------------
# Interruption queue + EventBridge rules
# ---------------------------------------------------------------------------

resource "aws_sqs_queue" "interruption" {
  name                       = "${local.name}-karpenter-interruption"
  visibility_timeout_seconds = 1200 # 20 minutes
  message_retention_seconds  = 300  # interruption notices are useless after a few minutes
  sqs_managed_sse_enabled    = true

  tags = merge(local.common_tags, { Name = "${local.name}-karpenter-interruption" })
}

resource "aws_cloudwatch_event_rule" "interruption" {
  for_each = local.interruption_events

  name          = "${local.name}-karpenter-${each.key}"
  description   = each.value.description
  event_pattern = jsonencode(each.value.pattern)

  tags = merge(local.common_tags, { Name = "${local.name}-karpenter-${each.key}" })
}

resource "aws_cloudwatch_event_target" "interruption" {
  for_each = local.interruption_events

  rule      = aws_cloudwatch_event_rule.interruption[each.key].name
  target_id = "KarpenterInterruptionQueue"
  arn       = aws_sqs_queue.interruption.arn
}

# Without this policy EventBridge cannot publish to the queue: events would match the rules but
# never reach Karpenter, so Spot terminations would not be handled gracefully.
data "aws_iam_policy_document" "queue" {
  statement {
    sid       = "AllowEventBridgeToPublish"
    effect    = "Allow"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.interruption.arn]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com", "sqs.amazonaws.com"]
    }

    # Only this module's four rules may publish
    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [for rule in aws_cloudwatch_event_rule.interruption : rule.arn]
    }
  }

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["sqs:*"]
    resources = [aws_sqs_queue.interruption.arn]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_sqs_queue_policy" "interruption" {
  queue_url = aws_sqs_queue.interruption.id
  policy    = data.aws_iam_policy_document.queue.json
}

# ---------------------------------------------------------------------------
# Controller IRSA role
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "controller_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Only the karpenter ServiceAccount may assume the role
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:sub"
      values   = ["system:serviceaccount:${var.karpenter_namespace}:${var.karpenter_service_account}"]
    }
  }
}

data "aws_iam_policy_document" "controller" {
  # Launching: the shared building blocks Karpenter does not own
  statement {
    sid     = "AllowScopedEC2InstanceAccessActions"
    actions = ["ec2:RunInstances", "ec2:CreateFleet"]
    resources = [
      "arn:${local.partition}:ec2:${local.region}::image/*",
      "arn:${local.partition}:ec2:${local.region}::snapshot/*",
      "arn:${local.partition}:ec2:${local.region}:*:security-group/*",
      "arn:${local.partition}:ec2:${local.region}:*:subnet/*",
    ]
  }

  # Launch templates must belong to this cluster
  statement {
    sid       = "AllowScopedEC2LaunchTemplateAccessActions"
    actions   = ["ec2:RunInstances", "ec2:CreateFleet"]
    resources = ["arn:${local.partition}:ec2:${local.region}:*:launch-template/*"]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/kubernetes.io/cluster/${var.cluster_name}"
      values   = ["owned"]
    }
    condition {
      test     = "StringLike"
      variable = "aws:ResourceTag/karpenter.sh/nodepool"
      values   = ["*"]
    }
  }

  # Resources Karpenter creates must be tagged for this cluster at creation time
  statement {
    sid     = "AllowScopedEC2InstanceActionsWithTags"
    actions = ["ec2:RunInstances", "ec2:CreateFleet", "ec2:CreateLaunchTemplate"]
    resources = [
      "arn:${local.partition}:ec2:${local.region}:*:fleet/*",
      "arn:${local.partition}:ec2:${local.region}:*:instance/*",
      "arn:${local.partition}:ec2:${local.region}:*:volume/*",
      "arn:${local.partition}:ec2:${local.region}:*:network-interface/*",
      "arn:${local.partition}:ec2:${local.region}:*:launch-template/*",
      "arn:${local.partition}:ec2:${local.region}:*:spot-instances-request/*",
    ]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes.io/cluster/${var.cluster_name}"
      values   = ["owned"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/eks:eks-cluster-name"
      values   = [var.cluster_name]
    }
    condition {
      test     = "StringLike"
      variable = "aws:RequestTag/karpenter.sh/nodepool"
      values   = ["*"]
    }
  }

  statement {
    sid     = "AllowScopedResourceCreationTagging"
    actions = ["ec2:CreateTags"]
    resources = [
      "arn:${local.partition}:ec2:${local.region}:*:fleet/*",
      "arn:${local.partition}:ec2:${local.region}:*:instance/*",
      "arn:${local.partition}:ec2:${local.region}:*:volume/*",
      "arn:${local.partition}:ec2:${local.region}:*:network-interface/*",
      "arn:${local.partition}:ec2:${local.region}:*:launch-template/*",
      "arn:${local.partition}:ec2:${local.region}:*:spot-instances-request/*",
    ]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes.io/cluster/${var.cluster_name}"
      values   = ["owned"]
    }
    condition {
      test     = "StringEquals"
      variable = "ec2:CreateAction"
      values   = ["RunInstances", "CreateFleet", "CreateLaunchTemplate"]
    }
  }

  statement {
    sid       = "AllowScopedResourceTagging"
    actions   = ["ec2:CreateTags"]
    resources = ["arn:${local.partition}:ec2:${local.region}:*:instance/*"]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/kubernetes.io/cluster/${var.cluster_name}"
      values   = ["owned"]
    }
    condition {
      test     = "StringLike"
      variable = "aws:ResourceTag/karpenter.sh/nodepool"
      values   = ["*"]
    }
    condition {
      test     = "ForAllValues:StringEquals"
      variable = "aws:TagKeys"
      values   = ["karpenter.sh/nodeclaim", "Name"]
    }
  }

  # Terminate / clean up only what belongs to this cluster
  statement {
    sid     = "AllowScopedDeletion"
    actions = ["ec2:TerminateInstances", "ec2:DeleteLaunchTemplate"]
    resources = [
      "arn:${local.partition}:ec2:${local.region}:*:instance/*",
      "arn:${local.partition}:ec2:${local.region}:*:launch-template/*",
    ]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/kubernetes.io/cluster/${var.cluster_name}"
      values   = ["owned"]
    }
    condition {
      test     = "StringLike"
      variable = "aws:ResourceTag/karpenter.sh/nodepool"
      values   = ["*"]
    }
  }

  # Read-only discovery, limited to this region (Describe* has no resource-level scoping)
  statement {
    sid = "AllowRegionalReadActions"
    actions = [
      "ec2:DescribeAvailabilityZones",
      "ec2:DescribeImages",
      "ec2:DescribeInstances",
      "ec2:DescribeInstanceTypeOfferings",
      "ec2:DescribeInstanceTypes",
      "ec2:DescribeLaunchTemplates",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeSpotPriceHistory",
      "ec2:DescribeSubnets",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [local.region]
    }
  }

  statement {
    sid       = "AllowSSMReadActions"
    actions   = ["ssm:GetParameter"]
    resources = ["arn:${local.partition}:ssm:${local.region}::parameter/aws/service/*"]
  }

  # pricing:GetProducts does not support resource-level permissions
  statement {
    sid       = "AllowPricingReadActions"
    actions   = ["pricing:GetProducts"]
    resources = ["*"]
  }

  statement {
    sid       = "AllowInterruptionQueueActions"
    actions   = ["sqs:DeleteMessage", "sqs:GetQueueUrl", "sqs:ReceiveMessage"]
    resources = [aws_sqs_queue.interruption.arn]
  }

  # iam:PassRole is evaluated against the ROLE ARN (an instance profile is not a PassRole target),
  # so it is scoped to the node role wrapped by the instance profile, and only for EC2.
  statement {
    sid       = "AllowPassingInstanceRole"
    actions   = ["iam:PassRole"]
    resources = [var.node_role_arn]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ec2.amazonaws.com"]
    }
  }

  # Karpenter looks up the pre-created instance profile (it never creates or changes profiles)
  statement {
    sid       = "AllowInstanceProfileReadActions"
    actions   = ["iam:GetInstanceProfile"]
    resources = [aws_iam_instance_profile.node.arn]
  }

  # Karpenter 1.9's instance-profile garbage collector lists the profiles it created under its
  # own path (karpenter/<region>/<cluster>/). Read-only and limited to that path; without it the
  # controller logs AccessDenied on every run. It never deletes the pre-created profile above.
  statement {
    sid       = "AllowInstanceProfileListActions"
    actions   = ["iam:ListInstanceProfiles"]
    resources = ["arn:${local.partition}:iam::${local.account_id}:instance-profile/karpenter/${local.region}/${var.cluster_name}/*"]
  }

  statement {
    sid       = "AllowAPIServerEndpointDiscovery"
    actions   = ["eks:DescribeCluster"]
    resources = [local.cluster_arn]
  }
}

resource "aws_iam_policy" "controller" {
  name        = "${local.name}-karpenter-policy"
  description = "Karpenter controller permissions for cluster ${var.cluster_name}"
  policy      = data.aws_iam_policy_document.controller.json

  tags = merge(local.common_tags, { Name = "${local.name}-karpenter-policy" })
}

resource "aws_iam_role" "controller" {
  name               = "${local.name}-karpenter-role"
  description        = "IRSA role for the Karpenter controller"
  assume_role_policy = data.aws_iam_policy_document.controller_assume.json

  tags = merge(local.common_tags, { Name = "${local.name}-karpenter-role" })
}

resource "aws_iam_role_policy_attachment" "controller" {
  role       = aws_iam_role.controller.name
  policy_arn = aws_iam_policy.controller.arn
}
