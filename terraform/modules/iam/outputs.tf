output "role_arn" {
  description = "ARN of the least-privilege IAM Role. Use this to reference the role in other modules."
  value       = aws_iam_role.ec2_s3_reader.arn
}

output "instance_profile_name" {
  description = "Name of the IAM Instance Profile to attach to EC2 instances."
  value       = aws_iam_instance_profile.ec2_profile.name
}
