# =============================================================================
# MODULE: VPC — High-Availability, Zero-Trust Network
#
# Provisions:
#   - VPC spanning two AZs
#   - Public subnets  (ALB / NAT Gateways)
#   - Private subnets (Application EC2 instances)
#   - Internet Gateway
#   - NAT Gateways (one per AZ — no single point of failure)
#   - Route tables (public → IGW, private → per-AZ NAT GW)
#   - VPC Flow Logs → CloudWatch (Zero-Trust: all traffic is logged)
#   - S3 Gateway VPC Endpoint (S3 traffic never crosses the internet)
# =============================================================================

# --- VPC ---
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.project_name}-${var.environment}-vpc"
  }
}

# --- Internet Gateway ---
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-${var.environment}-igw"
  }
}

# ---------------------------------------------------------------------------
# PUBLIC SUBNETS (one per AZ)
# Hosts: Application Load Balancers, NAT Gateways
# ---------------------------------------------------------------------------
resource "aws_subnet" "public" {
  count = length(var.availability_zones)

  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = var.availability_zones[count.index]
  # EC2 instances in public subnets get public IPs only if explicitly requested.
  # Load balancers receive their IPs via their own resource configuration.
  map_public_ip_on_launch = false

  tags = {
    Name = "${var.project_name}-${var.environment}-public-${var.availability_zones[count.index]}"
    Tier = "public"
  }
}

# ---------------------------------------------------------------------------
# PRIVATE SUBNETS (one per AZ)
# Hosts: Application EC2 instances — no direct inbound internet access
# ---------------------------------------------------------------------------
resource "aws_subnet" "private" {
  count = length(var.availability_zones)

  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]
  # Private subnets never assign public IPs
  map_public_ip_on_launch = false

  tags = {
    Name = "${var.project_name}-${var.environment}-private-${var.availability_zones[count.index]}"
    Tier = "private"
  }
}

# ---------------------------------------------------------------------------
# ELASTIC IPs FOR NAT GATEWAYS (one per AZ)
# ---------------------------------------------------------------------------
resource "aws_eip" "nat" {
  count  = length(var.availability_zones)
  domain = "vpc"

  # EIPs must not be released before the NAT GW that uses them
  depends_on = [aws_internet_gateway.main]

  tags = {
    Name = "${var.project_name}-${var.environment}-nat-eip-${count.index + 1}"
  }
}

# ---------------------------------------------------------------------------
# NAT GATEWAYS (one per AZ — high availability, no cross-AZ single point of failure)
# ---------------------------------------------------------------------------
resource "aws_nat_gateway" "main" {
  count = length(var.availability_zones)

  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  depends_on = [aws_internet_gateway.main]

  tags = {
    Name = "${var.project_name}-${var.environment}-nat-${var.availability_zones[count.index]}"
  }
}

# ---------------------------------------------------------------------------
# PUBLIC ROUTE TABLE
# Routes 0.0.0.0/0 → Internet Gateway
# ---------------------------------------------------------------------------
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-rt-public"
  }
}

resource "aws_route_table_association" "public" {
  count          = length(var.availability_zones)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# ---------------------------------------------------------------------------
# PRIVATE ROUTE TABLES (one per AZ)
# Each private subnet routes outbound traffic through its own AZ-local NAT GW.
# This prevents cross-AZ traffic (which costs money) and eliminates the
# scenario where a NAT GW failure in AZ-a takes down private subnets in AZ-b.
# ---------------------------------------------------------------------------
resource "aws_route_table" "private" {
  count  = length(var.availability_zones)
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main[count.index].id
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-rt-private-${var.availability_zones[count.index]}"
  }
}

resource "aws_route_table_association" "private" {
  count          = length(var.availability_zones)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# ===========================================================================
# ZERO-TRUST ADDITION 1: VPC FLOW LOGS
#
# Flow logs capture all IP traffic in/out of network interfaces in the VPC.
# This is mandatory under a Zero-Trust model: you cannot detect exfiltration,
# lateral movement, or anomalous behaviour without a full traffic audit trail.
#
# Logs → CloudWatch Logs → can be forwarded to a SIEM (e.g. Splunk, DataDog)
# ===========================================================================
resource "aws_cloudwatch_log_group" "vpc_flow_log" {
  name              = "/aws/vpc/flow-logs/${var.project_name}-${var.environment}"
  retention_in_days = 90  # 90-day retention for security audit compliance

  tags = {
    Name = "${var.project_name}-${var.environment}-vpc-flow-logs"
  }
}

resource "aws_flow_log" "main" {
  vpc_id          = aws_vpc.main.id
  traffic_type    = "ALL"   # Capture ACCEPT, REJECT, and ALL traffic
  iam_role_arn    = var.flow_log_cloudwatch_iam_role_arn
  log_destination = aws_cloudwatch_log_group.vpc_flow_log.arn

  tags = {
    Name = "${var.project_name}-${var.environment}-flow-log"
  }
}

# ===========================================================================
# ZERO-TRUST ADDITION 2: S3 GATEWAY VPC ENDPOINT
#
# Without this, EC2 instances in private subnets reach S3 via:
#   Private subnet → NAT Gateway → Internet Gateway → Public internet → S3
#
# This endpoint creates a private route:
#   Private subnet → VPC Endpoint → S3 (entirely within the AWS network)
#
# Benefits:
#   - Traffic to S3 never traverses the public internet (Zero-Trust: no
#     opportunity for interception or exfiltration via the NAT path)
#   - Lower cost (no NAT GW data processing charges for S3 traffic)
#   - Endpoint policy (below) restricts which S3 buckets are reachable —
#     even if the IAM role is somehow elevated, the endpoint itself acts
#     as a second enforcement layer.
# ===========================================================================
data "aws_iam_policy_document" "s3_endpoint_policy" {
  # Allow access only to the specific epermit bucket and AWS-managed buckets
  # (e.g. Amazon Linux 2 yum repos, SSM endpoints use S3 for patches).
  statement {
    sid    = "AllowSpecificS3Buckets"
    effect = "Allow"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions   = ["s3:GetObject", "s3:ListBucket"]
    resources = ["*"]  # The IAM role policy already scopes to the specific bucket;
                       # the endpoint policy is the network-layer enforcement.
  }

  # Explicit deny of any S3 action to buckets outside the allowed set.
  # This is a defence-in-depth layer: even if a process has broader IAM
  # permissions, it cannot reach arbitrary S3 buckets over this endpoint.
  statement {
    sid    = "DenyAllExceptEpermitBucket"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = ["s3:*"]

    not_resources = [
      "arn:aws:s3:::epermit-*",
      "arn:aws:s3:::epermit-*/*",
      # Allow AWS-owned repos needed for OS patching (Amazon Linux 2)
      "arn:aws:s3:::amazonlinux-*",
      "arn:aws:s3:::amazonlinux-*/*",
      "arn:aws:s3:::aws-ssm-*",
      "arn:aws:s3:::aws-ssm-*/*",
    ]
  }
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = concat(
    [aws_route_table.public.id],
    aws_route_table.private[*].id
  )

  policy = data.aws_iam_policy_document.s3_endpoint_policy.json

  tags = {
    Name = "${var.project_name}-${var.environment}-s3-endpoint"
  }
}
