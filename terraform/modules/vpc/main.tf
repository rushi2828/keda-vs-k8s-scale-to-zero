################################################################################
# VPC Module
# Creates the private network (VPC, subnets, NAT gateway, route tables)
# that the EKS cluster and all AWS resources live inside.
#
# WHY A SEPARATE MODULE?
# Keeping VPC logic separate means you can swap networking config without
# touching EKS or SQS — clean separation of concerns.
################################################################################

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  # Pick the first 3 AZs in the region for HA
  azs = slice(data.aws_availability_zones.available.names, 0, 3)
}

################################################################################
# VPC
################################################################################

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true  # Required for EKS
  enable_dns_support   = true  # Required for EKS

  tags = merge(var.tags, {
    Name = "${var.name}-vpc"
    # Karpenter needs to discover subnets via these tags
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  })
}

################################################################################
# Internet Gateway — allows public subnets to reach the internet
################################################################################

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = merge(var.tags, {
    Name = "${var.name}-igw"
  })
}

################################################################################
# Public Subnets — used for Load Balancers (ALB/NLB)
# Nodes do NOT run here; only the load balancer endpoints live in public subnets
################################################################################

resource "aws_subnet" "public" {
  count = length(local.azs)

  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 4, count.index)
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true

  tags = merge(var.tags, {
    Name = "${var.name}-public-${local.azs[count.index]}"
    # Required for AWS Load Balancer Controller to find these subnets
    "kubernetes.io/role/elb" = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  })
}

################################################################################
# Private Subnets — EKS worker nodes run here
# No direct internet access; outbound goes through NAT gateway
################################################################################

resource "aws_subnet" "private" {
  count = length(local.azs)

  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, count.index + length(local.azs))
  availability_zone = local.azs[count.index]

  tags = merge(var.tags, {
    Name = "${var.name}-private-${local.azs[count.index]}"
    # Required for internal Load Balancers
    "kubernetes.io/role/internal-elb" = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    # Karpenter uses this tag to discover which subnets to launch nodes in
    "karpenter.sh/discovery" = var.cluster_name
  })
}

################################################################################
# NAT Gateway — lets private subnet nodes reach the internet (e.g. pull images)
# Single NAT for cost savings in demo. Use one per AZ in production.
################################################################################

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = merge(var.tags, {
    Name = "${var.name}-nat-eip"
  })

  depends_on = [aws_internet_gateway.main]
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id  # NAT lives in first public subnet

  tags = merge(var.tags, {
    Name = "${var.name}-nat"
  })

  depends_on = [aws_internet_gateway.main]
}

################################################################################
# Route Tables
################################################################################

# Public route table: default route → internet gateway
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = merge(var.tags, { Name = "${var.name}-public-rt" })
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Private route table: default route → NAT gateway
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = merge(var.tags, { Name = "${var.name}-private-rt" })
}

resource "aws_route_table_association" "private" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

################################################################################
# VPC Endpoints (optional but recommended for cost + security)
# Allows EKS nodes to talk to AWS services WITHOUT going through NAT gateway
################################################################################

# S3 endpoint — free, saves NAT costs for ECR image pulls
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = merge(var.tags, { Name = "${var.name}-s3-endpoint" })
}

# SQS endpoint — allows KEDA to reach SQS without NAT
resource "aws_vpc_endpoint" "sqs" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.region}.sqs"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = merge(var.tags, { Name = "${var.name}-sqs-endpoint" })
}

# Security group for interface endpoints
resource "aws_security_group" "vpc_endpoints" {
  name        = "${var.name}-vpc-endpoints-sg"
  description = "Allow HTTPS traffic from VPC to AWS service endpoints"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
    description = "HTTPS from VPC"
  }

  tags = merge(var.tags, { Name = "${var.name}-vpc-endpoints-sg" })
}
