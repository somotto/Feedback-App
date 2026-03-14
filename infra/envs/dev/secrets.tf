resource "aws_secretsmanager_secret" "db_password" {
  name                    = "${var.app_name}/db_password"
  description             = "RDS master password for ${var.app_name}"
  recovery_window_in_days = 0
  tags                    = { Name = "${var.app_name}-db-password" }
}

resource "aws_secretsmanager_secret_version" "db_password" {
  secret_id     = aws_secretsmanager_secret.db_password.id
  secret_string = local.db_password
}

resource "aws_secretsmanager_secret" "app_secrets" {
  name                    = "${var.app_name}/app"
  description             = "Application secrets for ${var.app_name}"
  recovery_window_in_days = 0
  tags                    = { Name = "${var.app_name}-app-secrets" }
}

resource "aws_secretsmanager_secret_version" "app_secrets" {
  secret_id     = aws_secretsmanager_secret.app_secrets.id
  secret_string = jsonencode({ jwt_secret = "replace-in-production" })
}
