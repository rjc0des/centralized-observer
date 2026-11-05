#!/bin/bash
# Runs ON the AWS host as root, from an unpacked release (/opt/cop/releases/<tag>), via
# Run Command (scripts/aws.sh deploy / rollback). Writes .env from SSM and starts the stack
# with the AWS override. A new release directory changes every bind-mount path, so Compose
# recreates those containers with the new config; named volumes (project "cop") persist.
# A release that passes the checks below becomes /opt/cop/current (the rollback target).
set -euo pipefail
TAG=${1:?usage: deploy.sh <tag>}
# Physical path: run as /opt/cop/current/... (rollback), $PWD would be the symlink itself.
cd "$(dirname "$0")/../.." && cd "$(pwd -P)"
RELEASE=$PWD
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
COMPOSE_FILE=docker-compose.yml:docker-compose.aws.yml
ENVIRONMENT=aws
ECR_REGISTRY=$REGISTRY
IMAGE_TAG=$TAG
CADVISOR_CONTAINERD_SOCKET=/var/run/containerd/containerd.sock
PROMETHEUS_EXTERNAL_URL=http://127.0.0.1:19090
ALERTMANAGER_EXTERNAL_URL=http://127.0.0.1:19093
BACKUP_S3=s3://cop-aws-backups-$account/backups
EOF
} >.env

# The one-shot migrate jobs never reach Loki (they finish before Alloy sees them).
failed() {
  echo "deploy.sh: $TAG failed its checks; state and migration logs:" >&2
  docker compose ps -a --format '{{.Service}} {{.State}} {{.Status}}' >&2 || true
  docker compose logs --no-color --tail 50 ecommerce-migrate incident-migrate >&2 || true
}
trap failed ERR

docker compose up -d --wait --pull missing --quiet-pull --remove-orphans
# Loki and Alloy have no container healthcheck (distroless): check every endpoint, like make health.
for u in 9090/-/ready 9093/-/ready 3100/ready 12345/-/ready 3000/api/health 8080/health 8081/health 8025/readyz; do
  for i in $(seq 1 30); do
    curl -fs -o /dev/null -m 5 "http://127.0.0.1:$u" && break
    [ "$i" -lt 30 ] || { echo "deploy.sh: http://127.0.0.1:$u not ready after 90s" >&2; false; }
    sleep 3
  done
done
docker compose ps --format '{{.Service}} {{.Status}}'

# Passed: this release is current, the one before it previous. Keep only those two
# (older ones hold old .env copies).
cd /opt/cop
if [ -L current ] && [ "$(readlink -f current)" != "$RELEASE" ]; then ln -sfn "$(readlink -f current)" previous; fi
ln -sfn "$RELEASE" current
for d in releases/*/; do
  d=$(readlink -f "$d")
  [ "$d" = "$(readlink -f current)" ] || [ "$d" = "$(readlink -f previous 2>/dev/null)" ] || rm -rf "$d"
done

# Daily database backups to S3 (scripts/backup.sh), always from the current release.
cat >/etc/systemd/system/cop-backup.service <<'EOF'
[Unit]
Description=COP database backups to S3
[Service]
Type=oneshot
WorkingDirectory=/opt/cop/current
Environment=HOME=/root
ExecStart=/opt/cop/current/scripts/backup.sh
EOF
cat >/etc/systemd/system/cop-backup.timer <<'EOF'
[Unit]
Description=Daily COP database backups
[Timer]
OnCalendar=*-*-* 02:00:00 UTC
RandomizedDelaySec=15m
Persistent=true
[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now cop-backup.timer >/dev/null
echo "deployed $TAG"
