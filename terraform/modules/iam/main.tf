# =============================================================================
# MODULE: IAM — Least-Privilege EC2 Role (Zero-Trust)
#
# This role enforces three layers of access control:
#
#   Layer 1 — TRUST POLICY (who can assume this role)
#     Only the EC2 service can assume this role. No user or other service
#     can impersonate it. A Condition on aws:SourceAccount prevents
#     cross-account confused-deputy attacks.
#
#   Layer 2 — PERMISSION POLICY (what the role can do)
#     Explicitly allows s3:ListBucket and s3:GetObject on ONE specific bucket.
#     All other actions are implicitly denied by IAM default.
#
#   Layer 3 — EXPLICIT DENY (belt-and-suspenders)
#     An explicit Deny on s3:* for all resources EXCEPT the allowed bucket
#     overrides any accidental wildcard grants that might be attached to
#     this role later (e.g. via an AWS-managed policy applied by mistake).
#     Explicit Deny always wins in IAM evaluation — this is irreversible
#     regardless of what other policies say.
#
# This satisfies the Zero-Trust principle of "never trust, always verify":
# even if a misconfiguration grants broader access, the explicit deny
# ensures the blast radius is contained to one bucket.
# =============================================================================

# ---------------------------------------------------------------------------
# TRUST POLICY — Only EC2 may assume this role
# ---------------------------------------------------------------------------
data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "ec2_trust" {
  statement {
    sid     = "AllowEC2AssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }

    # Condition: prevents cross-account confused-deputy attacks.
    # Only EC2 instances in THIS account can assume this role.
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

# ---------------------------------------------------------------------------
# PERMISSION POLICY — Read-only access to ONE specific S3 bucket
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "s3_read_only" {

  # Allow listing the specific bucket (needed for most S3 SDK operations)
  statement {
    sid     = "AllowListSpecificBucket"
    effect  = "Allow"
    actions = ["s3:ListBucket"]
    resources = [
      "arn:aws:s3:::${var.s3_bucket_name}",
    ]
  }

  # Allow reading objects within the specific bucket only
  statement {
    sid     = "AllowGetObjectsInSpecificBucket"
    effect  = "Allow"
    actions = ["s3:GetObject"]
    resources = [
      "arn:aws:s3:::${var.s3_bucket_name}/*",
    ]
  }

  # ---------------------------------------------------------------------------
  # EXPLICIT DENY — Zero-Trust enforcement
  #
  # This statement uses NotResource (inverse resource matching):
  # it DENIES all s3:* actions against every resource that is NOT the
  # allowed bucket or its objects.
  #
  # Why this matters:
  #   - IAM explicit Deny always wins over any Allow (including managed policies)
  #   - If someone later attaches AdministratorAccess or AmazonS3FullAccess to
  #     this role, this Deny still prevents access to any other bucket
  #   - Defence-in-depth: the network layer (VPC Endpoint policy) also restricts
  #     which buckets are reachable, providing two independent enforcement points
  # ---------------------------------------------------------------------------
  statement {
    sid     = "ExplicitDenyAllOtherS3Buckets"
    effect  = "Deny"
    actions = ["s3:*"]

    not_resources = [
      "arn:aws:s3:::${var.s3_bucket_name}",
      "arn:aws:s3:::${var.s3_bucket_name}/*",
    ]
  }
}

# ---------------------------------------------------------------------------
# IAM ROLE
# ---------------------------------------------------------------------------
resource "aws_iam_role" "ec2_s3_reader" {
  name               = "${var.project_name}-${var.environment}-ec2-s3-reader-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_trust.json
  description        = "Least-privilege role: EC2 read-only access to ${var.s3_bucket_name}. Explicit deny on all other S3 resources."

  # Enforce a short session duration — tokens expire quickly, limiting the
  # window of exposure if credentials are somehow exfiltrated.
  max_session_duration = 3600  # 1 hour

  tags = {
    Name = "${var.project_name}-${var.environment}-ec2-s3-reader-role"
  }
}

# ---------------------------------------------------------------------------
# IAM POLICY (customer-managed, not inline — auditable and reusable)
# ---------------------------------------------------------------------------
resource "aws_iam_policy" "s3_read_only" {
  name        = "${var.project_name}-${var.environment}-s3-readonly-policy"
  description = "Grants read-only access to ${var.s3_bucket_name}. Explicitly denies all other S3 access."
  policy      = data.aws_iam_policy_document.s3_read_only.json

  tags = {
    Name = "${var.project_name}-${var.environment}-s3-readonly-policy"
  }
}

# ---------------------------------------------------------------------------
# POLICY ATTACHMENT
# ---------------------------------------------------------------------------
resource "aws_iam_role_policy_attachment" "attach_s3_read" {
  role       = aws_iam_role.ec2_s3_reader.name
  policy_arn = aws_iam_policy.s3_read_only.arn
}

# ---------------------------------------------------------------------------
# INSTANCE PROFILE
# Required to attach an IAM Role to an EC2 instance.
# The application references this profile by name when launching EC2 instances.
# ---------------------------------------------------------------------------
resource "aws_iam_instance_profile" "ec2_profile" {
  name = "${var.project_name}-${var.environment}-ec2-instance-profile"
  role = aws_iam_role.ec2_s3_reader.name

  tags = {
    Name = "${var.project_name}-${var.environment}-ec2-instance-profile"
  }
}
