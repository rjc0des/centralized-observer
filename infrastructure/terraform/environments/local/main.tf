# Local environment: every module applied to Floci (make infra).
# The terraform container sets fake credentials, AWS_REGION and AWS_ENDPOINT_URL
# (http://floci:4566); allowed_account_ids stops it if that ever points at real AWS.
# State is a local file (git-ignored).

terraform {
  required_version = "~> 1.16"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.70"
    }
  }
}

provider "aws" {
  allowed_account_ids = ["000000000000"]
  s3_use_path_style   = true

  default_tags {
    tags = {
      project     = "cop"
      environment = "local"
      managed_by  = "terraform"
    }
  }
}

# Secret values keyed by .env variable name; the terraform container builds this
# from .env (docker-compose.yml, TF_VAR_secrets). Never stored in state.
variable "secrets" {
  type      = map(string)
  ephemeral = true
  sensitive = true
}

locals {
  name = "cop-local"
  # Required secrets from .env.example. SMTP/Slack credentials are empty locally.
  secret_names = [
    "POSTGRES_PASSWORD", "ECOMMERCE_OWNER_PASSWORD", "ECOMMERCE_APP_PASSWORD",
    "INCIDENT_DB_PASSWORD", "INCIDENT_OWNER_PASSWORD", "INCIDENT_APP_PASSWORD", "INCIDENT_API_TOKEN",
    "REDIS_PASSWORD", "GRAFANA_ADMIN_PASSWORD",
  ]
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

module "network" {
  source            = "../../modules/network"
  name              = local.name
  availability_zone = "${data.aws_region.current.region}a"
}

module "backups" {
  source        = "../../modules/storage"
  name          = "${local.name}-backups-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
}

module "ecr" {
  source       = "../../modules/ecr"
  names        = ["cop/ecommerce-api", "cop/incident-api"]
  force_delete = true
}

module "secrets" {
  source = "../../modules/secrets"
  prefix = "/cop/local"
  names  = local.secret_names
  values = var.secrets
}

# On Floci without a Docker socket the instance is metadata only (no container,
# no UserData or SSM commands); the workloads run in Docker Compose instead.
module "host" {
  source              = "../../modules/host"
  name                = local.name
  subnet_id           = module.network.subnet_id
  security_group_id   = module.network.security_group_id
  secrets_path        = "/cop/local"
  ecr_repository_arns = module.ecr.arns
  bucket_arn          = module.backups.arn
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
