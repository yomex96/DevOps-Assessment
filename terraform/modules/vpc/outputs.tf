output "vpc_id" {
  description = "The ID of the provisioned VPC."
  value       = aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "IDs of the public subnets (for load balancers)."
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "IDs of the private subnets (for application EC2 instances)."
  value       = aws_subnet.private[*].id
}
