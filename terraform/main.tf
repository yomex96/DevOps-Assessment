# =============================================================================
# ROOT MAIN.TF — Module orchestration only.
# Provider config, backend, and version constraints live in providers.tf.
# Hardcoded values live nowhere — all configuration is in variables.tf.
# =============================================================================

# ---------------------------------------------------------------------------
# MODULE: VPC
# Provisions the highly-available network foundation:
#   - VPC spanning two AZs
#   - Public subnets (for Application Load Balancers)
#   - Private subnets (for application EC2 instances)
#   - NAT Gateways (one per AZ) for outbound internet from private subnets
#   - VPC Flow Logs (Zero-Trust observability — all traffic is logged)
#   - VPC Endpoints for S3 (private traffic never traverses the internet)
# ---------------------------------------------------------------------------
module "vpc" {
  source = "./modules/vpc"

  project_name         = var.project_name
  environment          = var.environment
  vpc_cidr             = var.vpc_cidr
  availability_zones   = var.availability_zones
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs

  # Flow log destination — IAM role for CloudWatch delivery
  flow_log_cloudwatch_iam_role_arn = aws_iam_role.vpc_flow_log.arn
}

# ---------------------------------------------------------------------------
# MODULE: IAM (Least-privilege EC2 role for S3 read)
# Creates a role that can ONLY read from epermit-secure-documents-prod.
# An explicit Deny covers all other S3 buckets and services.
# ---------------------------------------------------------------------------
module "iam" {
  source = "./modules/iam"

  project_name   = var.project_name
  environment    = var.environment
  s3_bucket_name = var.s3_secure_documents_bucket
}

# ---------------------------------------------------------------------------
# VPC FLOW LOG IAM ROLE (root-level — supports the VPC module)
# Allows VPC Flow Logs to write to CloudWatch Logs.
# Scoped only to the logs:CreateLogGroup / logs:PutLogEvents actions needed.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "flow_log_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "flow_log_permissions" {
  statement {
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogGroups",
      "logs:DescribeLogStreams",
    ]
    # Scope to log groups in this account and region only
    resources = ["arn:aws:logs:${var.aws_region}:*:log-group:/aws/vpc/flow-logs/${var.project_name}-${var.environment}*"]
  }
}

resource "aws_iam_role" "vpc_flow_log" {
  name               = "${var.project_name}-${var.environment}-vpc-flow-log-role"
  assume_role_policy = data.aws_iam_policy_document.flow_log_assume.json
  description        = "Allows VPC Flow Logs to publish to CloudWatch Logs."
}

resource "aws_iam_role_policy" "vpc_flow_log" {
  name   = "${var.project_name}-${var.environment}-vpc-flow-log-policy"
  role   = aws_iam_role.vpc_flow_log.id
  policy = data.aws_iam_policy_document.flow_log_permissions.json
}
