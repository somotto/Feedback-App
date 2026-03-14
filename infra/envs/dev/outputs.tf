output "alb_dns" {
  value = aws_lb.main.dns_name
}

output "alb_url" {
  value = "http://${aws_lb.main.dns_name}"
}

output "s3_bucket_name" {
  value = aws_s3_bucket.frontend.bucket
}

output "ecr_repository_url" {
  value = aws_ecr_repository.app.repository_url
}

output "rds_endpoint" {
  value     = aws_db_instance.main.address
  sensitive = true
}

output "ecs_cluster_name" {
  value = aws_ecs_cluster.main.name
}

