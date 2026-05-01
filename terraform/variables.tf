variable "aws_region" {
  description = "The AWS region to deploy infrastructure into."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "A short identifier for the project, used in resource naming."
  type        = string
  default     = "epermit"
}

variable "environment" {
  description = "Deployment environment (e.g. prod, staging, dev)."
  type        = string
  default     = "prod"

  validation {
    condition     = contains(["prod", "staging", "dev"], var.environment)
    error_message = "environment must be one of: prod, staging, dev."
  }
}

variable "vpc_cidr" {
  description = "The CIDR block for the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "List of Availability Zones to span. Minimum 2 for high availability."
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for the public subnets (one per AZ). Used for load balancers."
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for the private subnets (one per AZ). Used for application servers."
  type        = list(string)
  default     = ["10.0.11.0/24", "10.0.12.0/24"]
}

variable "s3_secure_documents_bucket" {
  description = "Name of the S3 bucket that EC2 instances are permitted to read from."
  type        = string
  default     = "epermit-secure-documents-prod"
}
