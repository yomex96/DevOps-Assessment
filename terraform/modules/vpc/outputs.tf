output "vpc_id" {
  description = "The ID of the provisioned VPC."
  value       = aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "IDs of the public subnets (for Application Load Balancers and NAT Gateways)."
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "IDs of the private subnets (for application EC2 instances)."
  value       = aws_subnet.private[*].id
}

output "s3_endpoint_id" {
  description = "ID of the S3 Gateway VPC Endpoint (ensures S3 traffic stays within the AWS network)."
  value       = aws_vpc_endpoint.s3.id
}

output "flow_log_group_name" {
  description = "CloudWatch Log Group name for VPC Flow Logs."
  value       = aws_cloudwatch_log_group.vpc_flow_log.name
}
