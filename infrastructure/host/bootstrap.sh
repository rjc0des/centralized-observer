#!/bin/bash
# EC2 UserData for the AWS host (Amazon Linux 2023, arm64), run once at first boot:
# Docker and the Compose plugin. Deploys come later through Run Command
# (scripts/aws.sh deploy -> infrastructure/host/deploy.sh). Log: /var/log/cloud-init-output.log
set -euxo pipefail

dnf install -y docker jq   # jq: tests/integration/aws.sh parses API replies on the host
systemctl enable --now docker

# Compose isn't packaged for AL2023: pinned release binary, checked against its published sha256.
COMPOSE_VERSION=v5.5.1
COMPOSE_SHA256=732e3a84c1a0f67256ce80bc2598a24546b10ca05f9faa97efceb1171ece2ef7
curl -fsSL -o /tmp/docker-compose \
  "https://github.com/docker/compose/releases/download/$COMPOSE_VERSION/docker-compose-linux-aarch64"
echo "$COMPOSE_SHA256  /tmp/docker-compose" | sha256sum -c -
install -D -m 0755 /tmp/docker-compose /usr/local/lib/docker/cli-plugins/docker-compose
rm /tmp/docker-compose

# 2 GiB swap: t4g.small has 2 GiB RAM and the stack ~1 GiB, so image pulls and startup
# spikes would otherwise invoke the OOM killer.
fallocate -l 2G /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
echo '/swapfile none swap defaults 0 0' >>/etc/fstab

install -d -m 0700 /opt/cop/releases
