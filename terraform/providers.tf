# =============================================================================
# PROVIDERS.TF
# Declares the Terraform version constraint, required providers, remote
# state backend, and AWS provider configuration.
# =============================================================================

terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket         = "epermit-terraform-state-prod"
    key            = "global/epermit/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "epermit-terraform-locks"
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "Terraform"
    }
  }
}
