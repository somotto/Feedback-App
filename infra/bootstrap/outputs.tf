output "s3_bucket_name" {
  value = aws_s3_bucket.tfstate.bucket
}

output "dynamodb_table_name" {
  value = aws_dynamodb_table.tfstate_lock.name
}

output "backend_config_snippet" {
  value = <<-EOT

    # ── Paste this into infra/envs/dev/main.tf backend block ──
    backend "s3" {
      bucket         = "${aws_s3_bucket.tfstate.bucket}"
      key            = "${var.app_name}/dev/terraform.tfstate"
      region         = "${var.aws_region}"
      dynamodb_table = "${aws_dynamodb_table.tfstate_lock.name}"
      encrypt        = true
    }
  EOT
}
