# =============================================================================
# ROOT MAIN.TF — Module orchestration only.
# Provider config, backend, and version constraints live in providers.tf.
# =============================================================================

# ---------------------------------------------------------------------------
# MODULE: VPC
# ---------------------------------------------------------------------------
module "vpc" {
  source = "./modules/vpc"

  project_name         = var.project_name
  environment          = var.environment
  vpc_cidr             = var.vpc_cidr
  availability_zones   = var.availability_zones
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
}

# ---------------------------------------------------------------------------
# MODULE: IAM (Least-privilege EC2 role for S3 read)
# ---------------------------------------------------------------------------
module "iam" {
  source = "./modules/iam"

  project_name   = var.project_name
  environment    = var.environment
  s3_bucket_name = var.s3_secure_documents_bucket
}
