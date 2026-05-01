# =============================================================================
# ROOT VARIABLES.TF
# No hardcoded values — all configuration is parameterised.
# Sensitive values (account IDs, secrets) must be passed at runtime via
# environment variables (TF_VAR_*) or a tfvars file that is never committed.
# =============================================================================

variable "aws_region" {
  description = "The AWS region to deploy infrastructure into. Override to eu-west-1 for DR failover."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "A short identifier for the project, used in resource naming and tagging."
  type        = string
  default     = "epermit"
}

variable "environment" {
  description = "Deployment environment. Controls naming conventions and tag values."
  type        = string
  default     = "prod"

  validation {
    condition     = contains(["prod", "staging", "dev"], var.environment)
    error_message = "environment must be one of: prod, staging, dev."
  }
}

variable "vpc_cidr" {
  description = "The IPv4 CIDR block for the VPC. Must not overlap with other VPCs (e.g. for VPC peering)."
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrnetmask(var.vpc_cidr))
    error_message = "vpc_cidr must be a valid IPv4 CIDR block (e.g. 10.0.0.0/16)."
  }
}

variable "availability_zones" {
  description = "List of Availability Zones to span. Minimum 2 for high availability. Must match aws_region."
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]

  validation {
    condition     = length(var.availability_zones) >= 2
    error_message = "At least 2 Availability Zones must be provided for high availability."
  }
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for the public subnets (one per AZ). These host load balancers and NAT Gateways."
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]

  validation {
    condition     = length(var.public_subnet_cidrs) == length(var.availability_zones)
    error_message = "public_subnet_cidrs must have one entry per availability zone."
  }
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for the private subnets (one per AZ). These host application EC2 instances."
  type        = list(string)
  default     = ["10.0.11.0/24", "10.0.12.0/24"]

  validation {
    condition     = length(var.private_subnet_cidrs) == length(var.availability_zones)
    error_message = "private_subnet_cidrs must have one entry per availability zone."
  }
}

variable "s3_secure_documents_bucket" {
  description = "Name of the S3 bucket that EC2 instances are permitted to read from. Must match the actual bucket name exactly."
  type        = string
  default     = "epermit-secure-documents-prod"
}
