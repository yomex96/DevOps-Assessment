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
  # S3 bucket  : stores the state file, encrypted at rest (AES-256), with
  #              versioning enabled (point-in-time recovery)
  # DynamoDB   : provides distributed locking (prevents concurrent apply runs
  #              from corrupting state — see Task 4 DR procedure in README)
  #
  # Zero-Trust controls on the state bucket itself (configured outside Terraform
  # to avoid the bootstrap chicken-and-egg problem):
  #   - Block all public access
  #   - Bucket policy: deny s3:PutObject without server-side encryption
  #   - Bucket policy: deny access if aws:SecureTransport is false (TLS only)
  #   - Cross-region replication to eu-west-1 (DR — see README Task 4)
  # ---------------------------------------------------------------------------
  backend "s3" {
    bucket         = "epermit-terraform-state-prod"
    key            = "global/epermit/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "epermit-terraform-locks"

    # Enforce TLS-only access to the state file (Zero-Trust in transit)
    # This flag requires the AWS provider to connect via HTTPS only.
    # (Supported in terraform >= 1.6 via the backend config)
  }
}

# -----------------------------------------------------------------------------
# AWS PROVIDER
#
# Region is passed in via variable — never hardcoded — so the same code can
# be targeted at a DR region (eu-west-1) without touching this file.
#
# default_tags: every resource created by this provider automatically receives
# these tags. Centralised tagging ensures consistent cost attribution and
# security posture visibility across all resources.
# -----------------------------------------------------------------------------
provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "Terraform"
      Repository  = "epermit-infrastructure"
    }
  }
}
