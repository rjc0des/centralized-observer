#!/bin/bash
# Runs ON the AWS host as root, from an unpacked release (/opt/cop/releases/<tag>), via
# Run Command (scripts/aws.sh deploy). Writes .env from SSM and starts the stack with the
# AWS override. A new release directory changes every bind-mount path, so Compose
# recreates those containers with the new config; named volumes (project "cop") persist.
set -euo pipefail
TAG=${1:?usage: deploy.sh <tag>}
cd "$(dirname "$0")/../.."
export HOME=/root AWS_REGION=ap-south-1

account=$(aws sts get-caller-identity --query Account --output text)
REGISTRY=$account.dkr.ecr.$AWS_REGION.amazonaws.com
aws ecr get-login-password | docker login --username AWS --password-stdin "$REGISTRY" >/dev/null
trap 'docker logout "$REGISTRY" >/dev/null' EXIT

# Secrets: /cop/aws/<ENV_VAR_NAME> -> ENV_VAR_NAME=value (hex/base64, no quoting needed).
umask 077
secrets=$(aws ssm get-parameters-by-path --path /cop/aws --with-decryption \
  --query 'Parameters[].[Name,Value]' --output text | sed 's|^/cop/aws/||; s|\t|=|')
# environments/aws writes 9; fewer means Compose would refuse to start anyway, less clearly.
[ "$(grep -c '^[A-Z_]*=.' <<<"$secrets")" -eq 9 ] || { echo "deploy.sh: expected 9 secrets under SSM /cop/aws" >&2; exit 1; }
{
  echo "$secrets"
  cat <<EOF
ENVIRONMENT=aws
ECR_REGISTRY=$REGISTRY
IMAGE_TAG=$TAG
CADVISOR_CONTAINERD_SOCKET=/var/run/containerd/containerd.sock
PROMETHEUS_EXTERNAL_URL=http://127.0.0.1:19090
ALERTMANAGER_EXTERNAL_URL=http://127.0.0.1:19093
EOF
} >.env

docker compose -f docker-compose.yml -f docker-compose.aws.yml up -d --wait --pull missing --quiet-pull --remove-orphans
docker compose -f docker-compose.yml -f docker-compose.aws.yml ps --format '{{.Service}} {{.Status}}'

# Older releases hold old .env copies: keep the current and the previous one.
ls -1dt /opt/cop/releases/*/ | tail -n +3 | xargs -r rm -rf
echo "deployed $TAG"
