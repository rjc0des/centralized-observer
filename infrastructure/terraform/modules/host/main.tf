# The platform host: one Graviton EC2 instance running the Docker Compose stack,
# with an instance role that can read its own secrets, pull its own images and
# write its own bucket. No SSH key: access is SSM Session Manager.

variable "name" {
  type = string
}

variable "instance_type" {
  type    = string
  default = "t4g.small"
}

variable "root_volume_gb" {
  type    = number
  default = 30
}

variable "subnet_id" {
  type = string
}

variable "security_group_id" {
  type = string
}

# SSM parameter path holding this host's secrets, e.g. /cop/aws.
variable "secrets_path" {
  type = string
}

variable "ecr_repository_arns" {
  type = list(string)
}

variable "bucket_arn" {
  type = string
}

data "aws_partition" "current" {}
data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

# Latest Amazon Linux 2023 for arm64, resolved by AWS's public SSM parameter.
data "aws_ssm_parameter" "ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  name               = var.name
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

data "aws_iam_policy_document" "host" {
  # Session Manager only, AWS's documented minimum. Not AmazonSSMManagedInstanceCore: it
  # grants ssm:GetParameter(s) on "*", i.e. every secret in the account, past ReadOwnSecrets.
  # ponytail: no Run Command (ec2messages:*); add it if deploys ever use SSM commands.
  statement {
    sid = "SessionManager"
    actions = [
      "ssm:UpdateInstanceInformation",
      "ssmmessages:CreateControlChannel", "ssmmessages:CreateDataChannel",
      "ssmmessages:OpenControlChannel", "ssmmessages:OpenDataChannel",
    ]
    resources = ["*"]
  }
  statement {
    sid     = "ReadOwnSecrets"
    actions = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
    resources = [
      "arn:${data.aws_partition.current.partition}:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter${var.secrets_path}",
      "arn:${data.aws_partition.current.partition}:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter${var.secrets_path}/*",
    ]
  }
  # GetAuthorizationToken has no resource-level permissions.
  statement {
    sid       = "EcrLogin"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    sid       = "PullOwnImages"
    actions   = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability"]
    resources = var.ecr_repository_arns
  }
  statement {
    sid       = "ListOwnBucket"
    actions   = ["s3:ListBucket"]
    resources = [var.bucket_arn]
  }
  # No delete actions: a compromised host can overwrite (versioned, recoverable), not erase.
  statement {
    sid       = "ReadWriteOwnBucket"
    actions   = ["s3:GetObject", "s3:PutObject"]
    resources = ["${var.bucket_arn}/*"]
  }
}

resource "aws_iam_role_policy" "host" {
  name   = "host"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.host.json
}

resource "aws_iam_instance_profile" "this" {
  name = var.name
  role = aws_iam_role.this.name
}

resource "aws_instance" "this" {
  ami                    = data.aws_ssm_parameter.ami.insecure_value
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [var.security_group_id]
  iam_instance_profile   = aws_iam_instance_profile.this.name

  # IMDSv2 only; hop limit 2 so containers on the host can reach it too.
  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_gb
    encrypted   = true
  }

  # All platform data (Prometheus, Loki, Postgres volumes) lives on this root volume and
  # is deleted with the instance: any replacement (-replace, taint, subnet change) loses it.
  # ponytail: one volume; add a separate EBS data volume or prevent_destroy in Phase 7.
  # A newer AMI alone must not trigger that replacement.
  lifecycle {
    ignore_changes = [ami]
  }

  tags = { Name = var.name }
}

output "instance_id" {
  value = aws_instance.this.id
}

output "role_arn" {
  value = aws_iam_role.this.arn
}
