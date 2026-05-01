output "role_arn" {
  description = "ARN of the least-privilege IAM Role. Attach to EC2 instances via the instance profile."
  value       = aws_iam_role.ec2_s3_reader.arn
}

output "instance_profile_name" {
  description = "Name of the IAM Instance Profile to specify when launching application EC2 instances."
  value       = aws_iam_instance_profile.ec2_profile.name
}

output "policy_arn" {
  description = "ARN of the S3 read-only IAM policy (customer-managed, auditable)."
  value       = aws_iam_policy.s3_read_only.arn
}
