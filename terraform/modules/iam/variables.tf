variable "project_name" {
  description = "Short project identifier used in resource naming."
  type        = string
}

variable "environment" {
  description = "Deployment environment (prod, staging, dev)."
  type        = string
}

variable "s3_bucket_name" {
  description = "Name of the S3 bucket this role is permitted to read from. No other bucket is accessible."
  type        = string
}
