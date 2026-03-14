#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")" && pwd)"
DEV_DIR="$PROJECT_ROOT/infra/envs/dev"
APP_NAME="web-api"
AWS_REGION="us-east-1"

echo "==> Emptying S3 frontend bucket before destroy..."
cd "$DEV_DIR"
BUCKET=$(terraform output -raw s3_bucket_name 2>/dev/null || echo "")
if [[ -n "$BUCKET" ]]; then
  aws s3 rm "s3://$BUCKET" --recursive
  echo "    Bucket emptied: $BUCKET"
fi

echo ""
echo "==> Destroying all infrastructure..."
terraform destroy -auto-approve \
  -var="app_name=$APP_NAME" \
  -var="aws_region=$AWS_REGION"

echo ""
echo "All infrastructure destroyed. No ongoing charges."
echo ""
echo "NOTE: The S3 state bucket and DynamoDB lock table are preserved"
echo "      (prevent_destroy = true). To remove them manually:"
echo "      cd infra/bootstrap && terraform destroy"
