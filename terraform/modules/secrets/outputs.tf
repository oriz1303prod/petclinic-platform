output "openai_secret_arn" {
  description = "Secrets Manager ARN of the OpenAI API key secret"
  value       = aws_secretsmanager_secret.openai_api_key.arn
}

output "config_server_git_username_secret_arn" {
  description = "Secrets Manager ARN of the Config Server Git username (null when not enabled)"
  value       = one(aws_secretsmanager_secret.config_server_git_username[*].arn)
}

output "config_server_git_password_secret_arn" {
  description = "Secrets Manager ARN of the Config Server Git password (null when not enabled)"
  value       = one(aws_secretsmanager_secret.config_server_git_password[*].arn)
}

output "eso_role_arn" {
  description = "IRSA role ARN for the External Secrets Operator ServiceAccount annotation (eks.amazonaws.com/role-arn)"
  value       = aws_iam_role.eso.arn
}
