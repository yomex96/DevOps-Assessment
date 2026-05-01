# =============================================================================
# ROOT OUTPUTS.TF
# Expose key identifiers needed by downstream consumers (e.g. application
# Terraform modules that reference this infrastructure layer).
# =============================================================================

output "vpc_id" {
  description = "The ID of the provisioned VPC."
  value       = module.vpc.vpc_id
}

output "public_subnet_ids" {
  description = "IDs of the public subnets (for Application Load Balancers)."
  value       = module.vpc.public_subnet_ids
}

output "private_subnet_ids" {
  description = "IDs of the private subnets (for application EC2 instances)."
  value       = module.vpc.private_subnet_ids
}

output "ec2_instance_profile_name" {
  description = "Name of the IAM Instance Profile to attach to application EC2 instances."
  value       = module.iam.instance_profile_name
}

output "ec2_role_arn" {
  description = "ARN of the least-privilege IAM Role for EC2 instances."
  value       = module.iam.role_arn
}

output "s3_vpc_endpoint_id" {
  description = "ID of the S3 Gateway VPC Endpoint (private traffic to S3 never leaves the AWS network)."
  value       = module.vpc.s3_endpoint_id
}
