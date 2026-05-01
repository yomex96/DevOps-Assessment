# =============================================================================
# PROVIDERS.TF
# Declares the Terraform version constraint, required providers, remote
# state backend, and AWS provider configuration.
#
# Convention: keep ALL provider and backend config here so main.tf contains
# only module/resource calls and is easy to scan at a glance.
# =============================================================================

terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # ---------------------------------------------------------------------------
  # REMOTE STATE BACKEND — S3 + DynamoDB
  #
  # S3 bucket  : stores the state file, encrypted at rest, versioning enabled
  # DynamoDB   : provides distributed locking (prevents concurrent apply runs
  #              from corrupting state)
  #
  # See README Task 4 for the full cross-region DR procedure for this state.
  # ---------------------------------------------------------------------------
  backend "s3" {
    bucket         = "epermit-terraform-state-prod"
    key            = "global/epermit/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "epermit-terraform-locks"
  }
}

# -----------------------------------------------------------------------------
# AWS PROVIDER
#
# Region is passed in via variable — never hardcoded — so the same code can
# be targeted at a DR region (eu-west-1) without touching this file.
#
# default_tags: every resource created by this provider automatically receives
# these tags. No need to repeat them on individual resources.
# -----------------------------------------------------------------------------
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
