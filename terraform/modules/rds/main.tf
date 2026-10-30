locals {
  name = "${var.project}-${var.environment}"

  # Mandatory tags come last so callers cannot override them
  common_tags = merge(
    var.tags,
    {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
      Component   = "rds"
    },
  )
}

# --- Credentials ---

resource "random_password" "master" {
  length  = 24
  special = true
  # Exclude characters RDS rejects (/ @ " space) and ones that break JDBC/URL handling
  override_special = "!#$%^&*()-_=+[]{}<>:?"
}

# Name follows the spec: petclinic/{env}/rds-credentials (default AWS KMS key aws/secretsmanager)
resource "aws_secretsmanager_secret" "rds_credentials" {
  name                    = "${var.project}/${var.environment}/rds-credentials"
  description             = "RDS MySQL master credentials for ${local.name}"
  recovery_window_in_days = var.secret_recovery_window_in_days

  tags = merge(local.common_tags, { Name = "${local.name}-rds-credentials" })
}

resource "aws_secretsmanager_secret_version" "rds_credentials" {
  secret_id = aws_secretsmanager_secret.rds_credentials.id

  secret_string = jsonencode({
    username = var.master_username
    password = random_password.master.result
  })
}

# --- Networking and parameters ---

resource "aws_db_subnet_group" "this" {
  name        = "${local.name}-mysql"
  description = "Subnets for ${local.name} RDS MySQL"
  subnet_ids  = var.subnet_ids

  tags = merge(local.common_tags, { Name = "${local.name}-mysql-subnet-group" })
}

resource "aws_db_parameter_group" "this" {
  name_prefix = "${local.name}-mysql84-"
  description = "utf8mb4 settings for ${local.name} RDS MySQL"
  family      = "mysql8.4"

  parameter {
    name  = "character_set_server"
    value = "utf8mb4"
  }

  parameter {
    name  = "collation_server"
    value = "utf8mb4_unicode_ci"
  }

  # Needed for the slowquery CloudWatch export to produce output
  parameter {
    name  = "slow_query_log"
    value = "1"
  }

  tags = merge(local.common_tags, { Name = "${local.name}-mysql84-params" })

  lifecycle {
    create_before_destroy = true
  }
}

# --- Logs (pre-created so retention is bounded; RDS would create them with no expiry) ---

resource "aws_cloudwatch_log_group" "rds" {
  for_each = toset(["error", "slowquery"])

  name              = "/aws/rds/instance/${local.name}-mysql/${each.key}"
  retention_in_days = var.log_retention_in_days

  tags = merge(local.common_tags, { Name = "${local.name}-mysql-${each.key}-logs" })
}

# --- Instance ---

resource "aws_db_instance" "this" {
  identifier = "${local.name}-mysql"

  engine         = "mysql"
  engine_version = var.engine_version
  instance_class = var.instance_class

  allocated_storage     = var.allocated_storage
  max_allocated_storage = var.max_allocated_storage > var.allocated_storage ? var.max_allocated_storage : null
  storage_type          = "gp2"
  storage_encrypted     = true # AWS managed key (aws/rds)

  db_name  = var.database_name
  username = var.master_username
  password = random_password.master.result
  port     = 3306

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [var.security_group_id]
  parameter_group_name   = aws_db_parameter_group.this.name

  # Subnets are public (cost optimization) but the instance gets no public IP;
  # the security group is the perimeter.
  publicly_accessible = false
  multi_az            = var.multi_az

  backup_retention_period   = var.backup_retention_period
  skip_final_snapshot       = var.skip_final_snapshot
  final_snapshot_identifier = var.skip_final_snapshot ? null : "${local.name}-mysql-final"
  copy_tags_to_snapshot     = true
  deletion_protection       = var.deletion_protection

  auto_minor_version_upgrade      = true
  enabled_cloudwatch_logs_exports = ["error", "slowquery"]

  tags = merge(local.common_tags, { Name = "${local.name}-mysql" })

  depends_on = [aws_cloudwatch_log_group.rds]
}
