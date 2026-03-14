#!/usr/bin/env bash
# deploy.sh — Run ONCE from your laptop to bootstrap everything.
# After this, all future deploys happen automatically via GitHub Actions on git push.
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")" && pwd)"
BOOTSTRAP_DIR="$PROJECT_ROOT/infra/bootstrap"
DEV_DIR="$PROJECT_ROOT/infra/envs/dev"
APP_NAME="web-api"
AWS_REGION="us-east-1"

#PREFLIGHT
echo "==> Checking required tools..."
for tool in aws terraform docker git; do
  command -v "$tool" &>/dev/null || { echo "ERROR: $tool not found"; exit 1; }
done

aws sts get-caller-identity --query 'Account' --output text &>/dev/null \
  || { echo "ERROR: AWS credentials not configured. Run: aws configure"; exit 1; }

#STEP 1: BOOTSTRAP STATE BACKEND
echo ""
echo "==> [1/4] Bootstrapping Terraform state backend (S3 + DynamoDB)..."
cd "$BOOTSTRAP_DIR"
terraform init -input=false
terraform apply -input=false -auto-approve \
  -var="app_name=$APP_NAME" \
  -var="aws_region=$AWS_REGION"

S3_BUCKET=$(terraform output -raw s3_bucket_name)
DYNAMO_TABLE=$(terraform output -raw dynamodb_table_name)
echo "    State bucket : $S3_BUCKET"
echo "    Lock table   : $DYNAMO_TABLE"

#STEP 2: AUTO-PATCH BACKEND BLOCK
echo ""
echo "==> [2/4] Patching backend config in infra/envs/dev/main.tf..."
MAIN_TF="$DEV_DIR/main.tf"
sed -i "s|bucket         = \".*\"|bucket         = \"$S3_BUCKET\"|" "$MAIN_TF"
sed -i "s|dynamodb_table = \".*\"|dynamodb_table = \"$DYNAMO_TABLE\"|" "$MAIN_TF"
echo "    Backend patched."

#STEP 3: APPLY FULL INFRASTRUCTURE
# DB password is read automatically from SSM — no manual input needed
echo ""
echo "==> [3/4] Applying full infrastructure (VPC, ECS, RDS, ALB)..."
cd "$DEV_DIR"
terraform init -input=false \
  -backend-config="bucket=$S3_BUCKET" \
  -backend-config="key=$APP_NAME/dev/terraform.tfstate" \
  -backend-config="region=$AWS_REGION" \
  -backend-config="dynamodb_table=$DYNAMO_TABLE" \
  -backend-config="encrypt=true" \
  -reconfigure

terraform apply -input=false -auto-approve \
  -var="app_name=$APP_NAME" \
  -var="aws_region=$AWS_REGION"

ECR_URI=$(terraform output -raw ecr_repository_url)
ALB_DNS=$(terraform output -raw alb_dns)
S3_FRONTEND=$(terraform output -raw s3_bucket_name)

#STEP 4: FIRST IMAGE PUSH FROM LAPTOP
echo ""
echo "==> [4/4] Building and pushing initial Docker image to ECR..."
GIT_SHA=$(git -C "$PROJECT_ROOT" rev-parse HEAD)
IMAGE_TAG="sha-$GIT_SHA"

aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "$ECR_URI"

docker build -t "$APP_NAME:$IMAGE_TAG" "$PROJECT_ROOT/app"
docker tag "$APP_NAME:$IMAGE_TAG" "$ECR_URI:$IMAGE_TAG"
docker push "$ECR_URI:$IMAGE_TAG"
echo "    Pushed: $ECR_URI:$IMAGE_TAG"

# Update task definition with the real image
terraform apply -input=false -auto-approve \
  -var="app_name=$APP_NAME" \
  -var="aws_region=$AWS_REGION" \
  -var="container_image=$ECR_URI:$IMAGE_TAG"

# Upload frontend to S3
aws s3 sync "$PROJECT_ROOT/frontend/" "s3://$S3_FRONTEND" --delete

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║           BOOTSTRAP COMPLETE ✅ — Infra is live              ║"
echo "╠══════════════════════════════════════════════════════════════╣"
printf "║  ALB URL  : http://%-43s║\n" "$ALB_DNS"
printf "║  ECR URI  : %-48s║\n" "$ECR_URI"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║  From now on — just git push to main.                        ║"
echo "║  GitHub Actions builds, pushes to ECR, and redeploys ECS.    ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "Add this secret to GitHub repo (Settings → Secrets → Actions):"
echo "  AWS_DEPLOY_ROLE_ARN = $(terraform output -raw github_actions_role_arn)"
