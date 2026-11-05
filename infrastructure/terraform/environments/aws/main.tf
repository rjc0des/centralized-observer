# AWS environment: every module applied to the real account (make aws-plan / aws-apply).
# Credentials come from profile "cop" (IAM user cop-deployer, infrastructure/iam/
# deployer-policy.json) in the terraform-aws container only; allowed_account_ids refuses
# any other account. Short-lived demo: deploy, verify, destroy (make aws-destroy).
# ponytail: local state (git-ignored); move to an S3 backend (use_lockfile) when CI applies (Phase 8).

terraform {
  required_version = "~> 1.16"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.70"
    }
  }
}

# From AWS_ACCOUNT_ID in .env (git-ignored: the repo is public).
variable "account_id" {
  type = string
  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "Set AWS_ACCOUNT_ID (12 digits) in .env."
  }
}

provider "aws" {
  allowed_account_ids = [var.account_id]

  default_tags {
    tags = {
      project     = "cop"
      environment = "aws"
      managed_by  = "terraform"
    }
  }
}

# Secret values keyed by .env variable name (TF_VAR_secrets); never stored in state.
variable "secrets" {
  type      = map(string)
  ephemeral = true
  sensitive = true
}

locals {
  name = "cop-aws"
  secret_names = [
    "POSTGRES_PASSWORD", "ECOMMERCE_OWNER_PASSWORD", "ECOMMERCE_APP_PASSWORD",
    "INCIDENT_DB_PASSWORD", "INCIDENT_OWNER_PASSWORD", "INCIDENT_APP_PASSWORD", "INCIDENT_API_TOKEN",
    "REDIS_PASSWORD", "GRAFANA_ADMIN_PASSWORD",
  ]
}

data "aws_region" "current" {}

module "network" {
  source            = "../../modules/network"
  name              = local.name
  availability_zone = "${data.aws_region.current.region}a"
}

# Backups and release bundles (releases/<tag>.tar.gz, written by scripts/aws.sh deploy).
# force_destroy/force_delete: a demo environment must destroy cleanly.
module "backups" {
  source        = "../../modules/storage"
  name          = "${local.name}-backups-${var.account_id}"
  force_destroy = true
}

module "ecr" {
  source       = "../../modules/ecr"
  names        = ["cop/ecommerce-api", "cop/incident-api"]
  force_delete = true
}

module "secrets" {
  source = "../../modules/secrets"
  prefix = "/cop/aws"
  names  = local.secret_names
  values = var.secrets
}

# The boundary policy (infrastructure/iam/host-boundary.json) is created by an admin, not
# here: a key that could edit it could lift it. See README "Deploying to AWS".
module "host" {
  source = "../../modules/host"
  name   = local.name
  # The free account plan only launches free-tier types; t4g.small (2 GiB) is the largest
  # arm64 one. The stack uses ~1 GiB; bootstrap.sh adds 2 GiB swap for pulls and spikes.
  instance_type        = "t4g.small"
  subnet_id            = module.network.subnet_id
  security_group_id    = module.network.security_group_id
  secrets_path         = "/cop/aws"
  ecr_repository_arns  = module.ecr.arns
  bucket_arn           = module.backups.arn
  permissions_boundary = "arn:aws:iam::${var.account_id}:policy/cop-host-boundary"
  user_data            = file("${path.module}/../../../host/bootstrap.sh")
}

output "bucket" {
  value = module.backups.name
}

output "ecr_urls" {
  value = module.ecr.urls
}

output "instance_id" {
  value = module.host.instance_id
}
