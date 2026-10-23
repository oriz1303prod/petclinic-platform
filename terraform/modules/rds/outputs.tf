output "endpoint" {
  description = "RDS endpoint hostname (without port)"
  value       = aws_db_instance.this.address
}

output "port" {
  description = "RDS port"
  value       = aws_db_instance.this.port
}

output "db_instance_id" {
  description = "RDS instance ID"
  value       = aws_db_instance.this.id
}

output "database_name" {
  description = "Name of the shared database"
  value       = aws_db_instance.this.db_name
}

output "secret_arn" {
  description = "ARN of the Secrets Manager secret holding the RDS credentials (for External Secrets Operator)"
  value       = aws_secretsmanager_secret.rds_credentials.arn
}

output "secret_name" {
  description = "Name of the Secrets Manager secret holding the RDS credentials"
  value       = aws_secretsmanager_secret.rds_credentials.name
}
