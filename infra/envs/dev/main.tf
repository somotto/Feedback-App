terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }

  # Remote state — encrypted, versioned, locked
  backend "s3" {
    bucket         = "web-api-tfstate-555012476084"
    key            = "web-api/dev/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "web-api-tfstate-lock"
    encrypt        = true
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = var.app_name
      Env       = var.environment
      ManagedBy = "Terraform"
      Owner     = "tid.devops"
    }
  }
}

data "aws_availability_zones" "available" { state = "available" }