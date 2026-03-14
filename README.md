# 🚀 Feedback App

> **Stack:** Node.js + Express → Docker → ECR → ECS on EC2 + ALB → RDS PostgreSQL → Secrets Manager → S3 → CloudWatch → SNS → CI/CD  

---

## 🏛️ Architecture

```
Browser
    │
    ▼
Application Load Balancer (ALB — public subnets)
    │  /          → serves frontend (index.html from Express)
    │  /healthz   → health check (no DB dependency)
    │  /db-check  → RDS connectivity test
    ▼
ECS Cluster (EC2 Launch Type — private subnets)
┌─────────────────────────────────────────┐
│  Auto Scaling Group (2x t3.small)       │
│  ┌─────────────┐  ┌─────────────┐       │
│  │ Container   │  │ Container   │       │
│  │ (Node.js)   │  │ (Node.js)   │       │
│  └─────────────┘  └─────────────┘       │
└─────────────────────────────────────────┘
    │
    ├──► RDS PostgreSQL 15.17 (private subnets, encrypted)
    └──► Secrets Manager (DB password injected at runtime)

GitHub Actions CI/CD:
  git push → test → build → push to ECR → rolling deploy on ECS

NOTE: CloudFront is disabled — new AWS accounts require Support verification
      before CloudFront resources can be created. Re-enable in cdn.tf once verified.
```

### Three Tiers
| Tier | Service | Notes |
|------|---------|-------|
| Presentation | Express `/` + S3 | Frontend served from ECS, S3 for storage |
| Application | ECS on EC2 + ALB | Containerised Node.js API |
| Data | RDS PostgreSQL 15.17 | Private subnets, encrypted at rest |

---

## 📁 Project Structure

```
Feedback App/
├── app/
│   ├── public/
│   │   └── index.html        # Frontend (served at / via Express)
│   ├── index.js              # Node.js Express API
│   ├── package.json
│   └── Dockerfile
├── frontend/
│   └── index.html            # Source frontend (copied to app/public/)
├── infra/
│   ├── bootstrap/            # One-time: creates S3 state bucket + DynamoDB lock
│   │   ├── main.tf
│   │   ├── outputs.tf
│   │   └── variables.tf
│   └── envs/
│       └── dev/
│           ├── main.tf       # Provider + S3 backend config
│           ├── variables.tf  # Reads db_password from SSM automatically
│           ├── vpc.tf        # VPC, subnets, IGW, NAT, route tables
│           ├── security.tf   # Security groups + IAM roles
│           ├── ecr.tf        # Container registry
│           ├── ecs.tf        # Cluster, ASG, ALB, task definition, service
│           ├── rds.tf        # PostgreSQL instance
│           ├── secrets.tf    # Secrets Manager entries
│           ├── cdn.tf        # S3 bucket (CloudFront disabled)
│           ├── monitoring.tf # CloudWatch alarms + SNS
│           ├── iam_github.tf # GitHub Actions OIDC role
│           ├── outputs.tf
│           └── terraform.tfvars
├── .github/
│   └── workflows/
│       └── deploy.yml        # CI/CD pipeline
├── deploy.sh                 # One-time bootstrap script
├── destroy.sh                # Teardown script
└── README.md
```

---

## 🚀 How to Deploy

### Prerequisites
```bash
aws --version        # AWS CLI v2
terraform --version  # >= 1.5
docker --version     # Docker running
git --version
gh --version         # GitHub CLI

aws sts get-caller-identity  # Confirm AWS credentials
```

### Step 1 — Store DB password in SSM (one-time)
```bash
aws ssm put-parameter \
  --name "/web-api/db_password" \
  --value "YourSecurePassword!" \
  --type "SecureString" \
  --region us-east-1
```
Terraform reads this automatically. You never type the password again.

### Step 2 — Bootstrap + deploy everything
```bash
./deploy.sh
```
This does in one command:
1. Creates S3 state bucket + DynamoDB lock table (`infra/bootstrap/`)
2. Patches the backend config in `main.tf` automatically
3. Applies all infrastructure (VPC, ECS, RDS, ALB, Secrets Manager, IAM)
4. Builds Docker image, pushes to ECR tagged with git SHA
5. Updates ECS task definition with the real image
6. Uploads frontend to S3

Takes ~15–20 minutes (RDS is the slow part).

### Step 3 — Add GitHub secret (one-time after deploy.sh)
```bash
# Get the role ARN
cd infra/envs/dev && terraform output github_actions_role_arn

# Add to GitHub
gh secret set AWS_DEPLOY_ROLE_ARN --body "<ARN from above>"
```

### Step 4 — All future deploys are automatic
```bash
git push origin main
# GitHub Actions: test → build → push to ECR → rolling deploy on ECS
```

---

## 🔄 CI/CD Pipeline (deploy.yml)

```
git push to main
    │
    ├── test        npm install + hit /healthz to confirm app starts
    │
    ├── build-and-push
    │     docker build → push to ECR as sha-<full-commit-sha>
    │     (OIDC auth — no AWS keys stored in GitHub)
    │
    └── deploy
          Get current ECS task definition
          Swap image to new SHA
          Register new task definition revision
          Update ECS service → rolling deploy
          Wait for services-stable
```

**Rolling deploy — zero downtime:**
- ECS starts new containers with the new image
- ALB health checks confirm they're healthy
- Old containers are stopped only after new ones pass health checks
- No new EC2 instances created — containers are replaced on existing EC2s

---

## 🧪 Live Endpoints

| Endpoint | Description |
|----------|-------------|
| `/` | Demo frontend — tests all endpoints live |
| `/healthz` | Health check (no DB) — used by ALB |
| `/db-check` | RDS connectivity test |
| `/ratings` | Get all ratings + summary stats |
| `/rating` | POST — submit a rating (1–5) |

---

## 💰 Estimated Cost (while running)

| Resource | Spec | Est/Month |
|----------|------|-----------|
| NAT Gateway | 1x | ~$45 |
| EC2 (ECS) | 2x t3.small | ~$30 |
| RDS PostgreSQL | db.t3.micro | ~$25 |
| ALB | 1x | ~$20 |
| S3 + ECR | Storage | ~$2 |
| **Total** | | **~$122/mo** |

> ⚠️ Run `./destroy.sh` after the demo to avoid charges.

---

## 🗑️ Teardown
```bash
./destroy.sh
```
Destroys everything in dependency order. The S3 state bucket and DynamoDB lock table are preserved (`prevent_destroy = true`).

---

## 🔑 Key Design Decisions

| Decision | Why |
|----------|-----|
| DB password in SSM | Never typed manually, never in code, Terraform reads it automatically |
| ECS task execution role has ECR pull policy | EC2 instances need explicit permission to pull images |
| No Terraform in CI/CD | CI only needs ECR push + ECS task def update — minimal IAM permissions |
| `/healthz` has no DB dependency | ALB health check must not fail when DB is slow |
| Image tagged with full git SHA | Know exactly what code is running in production at all times |
| `prevent_destroy` on state bucket | A stray `terraform destroy` can never wipe your state |
