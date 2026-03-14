# ─── GITHUB ACTIONS OIDC PROVIDER
# Allows GitHub Actions to authenticate to AWS without long-lived keys.
# GitHub presents a short-lived token; AWS validates it against this provider.
data "aws_caller_identity" "current" {}

resource "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"

  client_id_list = ["sts.amazonaws.com"]

  # GitHub's OIDC thumbprint (stable — changes only if GitHub rotates their cert)
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

#GITHUB ACTIONS DEPLOY ROLE
# GitHub Actions assumes this role via OIDC.
# Scope it to your exact repo so no other repo can assume it.
resource "aws_iam_role" "github_actions" {
  name = "github-actions-deploy"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.github.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          
          "token.actions.githubusercontent.com:sub" = "repo:Ngumonelson123/localhost-to-cloud:*"
        }
      }
    }]
  })
}

#PERMISSIONS: push to ECR + redeploy ECS only
resource "aws_iam_role_policy" "github_actions" {
  name = "ecr-ecs-deploy"
  role = aws_iam_role.github_actions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ECRAuth"
        Effect = "Allow"
        Action = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Sid    = "ECRPush"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:CompleteLayerUpload",
          "ecr:InitiateLayerUpload",
          "ecr:PutImage",
          "ecr:UploadLayerPart",
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer"
        ]
        Resource = aws_ecr_repository.app.arn
      },
      {
        Sid    = "ECSRedeploy"
        Effect = "Allow"
        Action = [
          "ecs:UpdateService",
          "ecs:DescribeServices",
          "ecs:RegisterTaskDefinition",
          "ecs:DescribeTaskDefinition",
          "ecs:ListTaskDefinitions",
          "ecs:DeregisterTaskDefinition"
        ]
        Resource = "*"
      },
      {
        Sid      = "PassRoleToECS"
        Effect   = "Allow"
        Action   = ["iam:PassRole"]
        Resource = aws_iam_role.ecs_execution.arn
      }
    ]
  })
}

output "github_actions_role_arn" {
  value       = aws_iam_role.github_actions.arn
  description = "Paste this ARN into deploy.yml role-to-assume"
}
