variable "aws_region"      { default = "us-east-1" }
variable "app_name"        { default = "web-api" }
variable "environment"     { default = "dev" }
variable "container_image" { default = "placeholder" }

# Read DB password from SSM — never typed manually or stored in code
data "aws_ssm_parameter" "db_password" {
  name            = "/web-api/db_password"
  with_decryption = true
}

locals {
  db_password = data.aws_ssm_parameter.db_password.value
}
