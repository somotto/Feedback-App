resource "random_id" "suffix" { byte_length = 4 }

# BUCKET (frontend static files)
resource "aws_s3_bucket" "frontend" {
  bucket = "${var.app_name}-frontend-${random_id.suffix.hex}"
  tags   = { Name = "${var.app_name}-frontend" }
}

resource "aws_s3_bucket_public_access_block" "frontend" {
  bucket                  = aws_s3_bucket.frontend.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "frontend" {
  bucket = aws_s3_bucket.frontend.id
  versioning_configuration { status = "Enabled" }
}

# NOTE: CloudFront is disabled — account requires AWS Support verification
# before CloudFront resources can be created. For this demo the ALB serves
# as the entry point. CloudFront can be re-enabled once account is verified:

