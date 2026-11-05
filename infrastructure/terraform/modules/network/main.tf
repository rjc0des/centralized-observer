# One VPC with one public subnet and one security group for the platform host.
# ponytail: single AZ, no NAT gateway, no private subnet. One t4g host doesn't need
# them and a NAT gateway costs ~$35/month. Add private subnets + NAT (or VPC endpoints)
# when there is more than one host or anything that must not have a public IP.

variable "name" {
  type = string
}

variable "cidr" {
  type    = string
  default = "10.40.0.0/16"
}

variable "public_subnet_cidr" {
  type    = string
  default = "10.40.1.0/24"
}

variable "availability_zone" {
  type = string
}

# Inbound rules for the host. Empty by default: humans use SSM Session Manager,
# not SSH, so nothing needs to be open.
variable "ingress" {
  type = list(object({
    description = string
    port        = number
    cidr        = string
  }))
  default = []
}

resource "aws_vpc" "this" {
  #checkov:skip=CKV2_AWS_11:Flow logs cost CloudWatch ingestion; the host has no inbound rules. Add with a long-lived environment.
  cidr_block           = var.cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = var.name }
}

# The default security group allows all traffic between its members; strip its rules
# so nothing ends up in it by accident.
resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = var.name }
}

resource "aws_subnet" "public" {
  #checkov:skip=CKV_AWS_130:A public IP gives the host egress without a NAT gateway (~$32/month); its security group has no ingress.
  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = true
  tags                    = { Name = "${var.name}-public" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name}-public" }
}

resource "aws_route" "internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "host" {
  #checkov:skip=CKV2_AWS_5:Attached to the host instance through the host module (security_group_id).
  name        = "${var.name}-host"
  description = "Platform host"
  vpc_id      = aws_vpc.this.id
  tags        = { Name = "${var.name}-host" }
}

resource "aws_vpc_security_group_ingress_rule" "host" {
  for_each = { for r in var.ingress : "${r.port}-${r.cidr}" => r }

  security_group_id = aws_security_group.host.id
  description       = each.value.description
  ip_protocol       = "tcp"
  from_port         = each.value.port
  to_port           = each.value.port
  cidr_ipv4         = each.value.cidr
}

# Outbound HTTPS only: package installs, ECR pulls, SSM, S3. SMTP or Slack go over 443/587.
resource "aws_vpc_security_group_egress_rule" "https" {
  security_group_id = aws_security_group.host.id
  description       = "HTTPS"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "smtp" {
  security_group_id = aws_security_group.host.id
  description       = "SMTP submission (alert email)"
  ip_protocol       = "tcp"
  from_port         = 587
  to_port           = 587
  cidr_ipv4         = "0.0.0.0/0"
}

output "vpc_id" {
  value = aws_vpc.this.id
}

output "subnet_id" {
  value = aws_subnet.public.id
}

output "security_group_id" {
  value = aws_security_group.host.id
}
