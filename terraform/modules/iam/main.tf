data "aws_iam_policy_document" "ec2_trust" {
  statement {
    sid     = "AllowEC2AssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "s3_read_only" {
  statement {
    sid     = "AllowListSpecificBucket"
    effect  = "Allow"
    actions = ["s3:ListBucket"]
    resources = [
      "arn:aws:s3:::${var.s3_bucket_name}",
    ]
  }

  statement {
    sid     = "AllowGetObjectsInSpecificBucket"
    effect  = "Allow"
    actions = ["s3:GetObject"]
    resources = [
      "arn:aws:s3:::${var.s3_bucket_name}/*",
    ]
  }

  statement {
    sid     = "ExplicitDenyAllOtherBuckets"
    effect  = "Deny"
    actions = ["s3:*"]
    not_resources = [
      "arn:aws:s3:::${var.s3_bucket_name}",
      "arn:aws:s3:::${var.s3_bucket_name}/*",
    ]
  }
}

resource "aws_iam_role" "ec2_s3_reader" {
  name               = "${var.project_name}-${var.environment}-ec2-s3-reader-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_trust.json
  description        = "Least-privilege role: allows EC2 to read from ${var.s3_bucket_name} only."

  tags = {
    Name = "${var.project_name}-${var.environment}-ec2-s3-reader-role"
  }

  # Prevent accidental destruction of a role attached to running EC2 instances.
  # For a government production service, terraform destroy must be an explicit
  # decision — not an accidental consequence of a mis-scoped plan.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_iam_policy" "s3_read_only" {
  name        = "${var.project_name}-${var.environment}-s3-readonly-policy"
  description = "Grants read-only access to ${var.s3_bucket_name}. Explicitly denies all other S3 access."
  policy      = data.aws_iam_policy_document.s3_read_only.json
}

resource "aws_iam_role_policy_attachment" "attach_s3_read" {
  role       = aws_iam_role.ec2_s3_reader.name
  policy_arn = aws_iam_policy.s3_read_only.arn
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "${var.project_name}-${var.environment}-ec2-instance-profile"
  role = aws_iam_role.ec2_s3_reader.name
}
