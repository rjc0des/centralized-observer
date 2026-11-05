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

# ARN of the policy capping this role (infrastructure/iam/host-boundary.json). Required:
# the deploy key may only create roles that carry it, so it can't mint an admin role.
variable "permissions_boundary" {
  type = string
}

# Cloud-init script run once at first boot (installs Docker); null on Floci.
variable "user_data" {
  type    = string
  default = null
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
  name                 = var.name
  assume_role_policy   = data.aws_iam_policy_document.assume.json
  permissions_boundary = var.permissions_boundary
}

data "aws_iam_policy_document" "host" {
  #checkov:skip=CKV_AWS_111:Only actions without resource-level permissions use "*" (SSM agent channels, ecr:GetAuthorizationToken).
  #checkov:skip=CKV_AWS_356:Same: those actions cannot be scoped to a resource.
  # SSM agent: Session Manager (ssmmessages) and Run Command, which deploys use
  # (ec2messages). Not AmazonSSMManagedInstanceCore: it grants ssm:GetParameter(s) on "*",
  # i.e. every secret in the account, past ReadOwnSecrets. ec2messages:DeleteMessage only
  # removes the agent's own delivered command from its queue.
  statement {
    sid = "SessionManager"
    actions = [
      "ssm:UpdateInstanceInformation",
      "ssmmessages:CreateControlChannel", "ssmmessages:CreateDataChannel",
      "ssmmessages:OpenControlChannel", "ssmmessages:OpenDataChannel",
      "ec2messages:GetEndpoint", "ec2messages:GetMessages", "ec2messages:AcknowledgeMessage",
      "ec2messages:SendReply", "ec2messages:FailMessage", "ec2messages:DeleteMessage",
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
  #checkov:skip=CKV_AWS_126:Node Exporter scrapes host metrics every 15s; detailed CloudWatch monitoring would cost extra for less.
  #checkov:skip=CKV_AWS_135:Graviton (t4g) instances are EBS-optimized by default; the flag is a no-op.
  ami                    = data.aws_ssm_parameter.ami.insecure_value
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [var.security_group_id]
  iam_instance_profile   = aws_iam_instance_profile.this.name
  user_data              = var.user_data

  # IMDSv2 only, hop limit 1: only the host itself (deploy.sh) gets the role's credentials.
  # With 2, any bridge-networked container could fetch them (verified on AWS) and read
  # every secret under the host's SSM path.
  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_gb
    encrypted   = true
  }

  # All platform data (Prometheus, Loki, Postgres volumes) lives on this root volume and
  # is deleted with the instance: any replacement (-replace, taint, subnet change) loses it.
  # ponytail: one volume; add a separate EBS data volume or prevent_destroy in Phase 7.
  # A newer AMI alone must not trigger that replacement. user_data runs only at first boot:
  # an edit would stop/start the host and still not run, so it applies to new hosts only.
  lifecycle {
    ignore_changes = [ami, user_data]
  }

  tags = { Name = var.name }
}

output "instance_id" {
  value = aws_instance.this.id
}

output "role_arn" {
  value = aws_iam_role.this.arn
}
