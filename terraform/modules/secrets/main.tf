locals {
  name = "${var.project}-${var.environment}"

  # Secrets Manager names use the slash convention from the spec: petclinic/{env}/...
  secret_prefix = "${var.project}/${var.environment}"

  # Mandatory tags come last so callers cannot override them
  common_tags = merge(
    var.tags,
    {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
      Component   = "secrets"
    },
  )
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# --- Application secrets (RDS credentials live in the rds module, not here) ---
# All secrets use the default AWS managed key (aws/secretsmanager), so ESO needs no kms:Decrypt.

resource "aws_secretsmanager_secret" "openai_api_key" {
  name                    = "${local.secret_prefix}/openai-api-key"
  description             = "OpenAI API key for the genai-service (${var.environment})"
  recovery_window_in_days = var.recovery_window_in_days

  tags = merge(local.common_tags, { Name = "${local.name}-openai-api-key" })
}

resource "aws_secretsmanager_secret_version" "openai_api_key" {
  secret_id     = aws_secretsmanager_secret.openai_api_key.id
  secret_string = var.openai_api_key
}

# --- Optional: Config Server Git credentials ---

resource "aws_secretsmanager_secret" "config_server_git_username" {
  count = var.enable_config_server_git_secrets ? 1 : 0

  name                    = "${local.secret_prefix}/config-server/git-username"
  description             = "Git username for the Config Server repository (${var.environment})"
  recovery_window_in_days = var.recovery_window_in_days

  tags = merge(local.common_tags, { Name = "${local.name}-config-server-git-username" })
}

resource "aws_secretsmanager_secret_version" "config_server_git_username" {
  count = var.enable_config_server_git_secrets ? 1 : 0

  secret_id     = aws_secretsmanager_secret.config_server_git_username[0].id
  secret_string = var.config_server_git_username

  lifecycle {
    precondition {
      condition     = var.config_server_git_username != null
      error_message = "config_server_git_username is required when enable_config_server_git_secrets is true."
    }
  }
}

resource "aws_secretsmanager_secret" "config_server_git_password" {
  count = var.enable_config_server_git_secrets ? 1 : 0

  name                    = "${local.secret_prefix}/config-server/git-password"
  description             = "Git password or token for the Config Server repository (${var.environment})"
  recovery_window_in_days = var.recovery_window_in_days

  tags = merge(local.common_tags, { Name = "${local.name}-config-server-git-password" })
}

resource "aws_secretsmanager_secret_version" "config_server_git_password" {
  count = var.enable_config_server_git_secrets ? 1 : 0

  secret_id     = aws_secretsmanager_secret.config_server_git_password[0].id
  secret_string = var.config_server_git_password

  lifecycle {
    precondition {
      condition     = var.config_server_git_password != null
      error_message = "config_server_git_password is required when enable_config_server_git_secrets is true."
    }
  }
}

# --- IRSA role for External Secrets Operator (PETPLAT-37) ---
# The ClusterSecretStore uses jwt auth with the external-secrets-sa ServiceAccount, so the trust
# policy is scoped to exactly that ServiceAccount (see the IRSA section of the technical spec).

data "aws_iam_policy_document" "eso_assume" {
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

    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:sub"
      values   = ["system:serviceaccount:${var.eso_namespace}:${var.eso_service_account}"]
    }
  }
}

# Read-only, limited to this environment's secrets. Secrets Manager appends a random suffix to
# the ARN, so the trailing /* covers secrets such as petclinic/dev/openai-api-key-AbCdEf.
data "aws_iam_policy_document" "eso_read" {
  statement {
    sid = "ReadPetclinicSecrets"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]
    resources = [
      "arn:aws:secretsmanager:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:secret:${local.secret_prefix}/*",
    ]
  }
}

resource "aws_iam_policy" "eso" {
  name        = "${local.name}-eso-policy"
  description = "Read ${local.secret_prefix}/* secrets from Secrets Manager (External Secrets Operator)"
  policy      = data.aws_iam_policy_document.eso_read.json

  tags = merge(local.common_tags, { Name = "${local.name}-eso-policy" })
}

resource "aws_iam_role" "eso" {
  name               = "${local.name}-eso-role"
  description        = "IRSA role for External Secrets Operator"
  assume_role_policy = data.aws_iam_policy_document.eso_assume.json

  tags = merge(local.common_tags, { Name = "${local.name}-eso-role" })
}

resource "aws_iam_role_policy_attachment" "eso" {
  role       = aws_iam_role.eso.name
  policy_arn = aws_iam_policy.eso.arn
}
