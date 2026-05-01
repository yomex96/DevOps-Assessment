variable "project_name" {
  description = "Short project identifier used in resource naming."
  type        = string
}

variable "environment" {
  description = "Deployment environment (prod, staging, dev)."
  type        = string
}

variable "vpc_cidr" {
  description = "The CIDR block for the VPC."
  type        = string
}

variable "availability_zones" {
  description = "List of AZs to deploy subnets into. Minimum 2 for high availability."
  type        = list(string)
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets (one per AZ). Used for load balancers and NAT Gateways."
  type        = list(string)
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets (one per AZ). Used for application servers."
  type        = list(string)
}

variable "flow_log_cloudwatch_iam_role_arn" {
  description = "ARN of the IAM Role that allows VPC Flow Logs to write to CloudWatch Logs."
  type        = string
}

variable "aws_region" {
  description = "AWS region — needed to construct the S3 VPC endpoint service name."
  type        = string
  default     = "us-east-1"
}
