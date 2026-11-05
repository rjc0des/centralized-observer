#!/usr/bin/env bash
# CI only: write .env from .env.example with fresh random secrets (never printed, never
# reused across runs). Optional AWS_ACCOUNT_ID comes from the environment (deploy job).
set -euo pipefail
cd "$(dirname "$0")/.."
[ ! -e .env ] || { echo "ci-env.sh: .env exists, not overwriting" >&2; exit 1; }

umask 077
cp .env.example .env
set_var() { sed -i.bak "s|^$1=.*|$1=$2|" .env && grep -q "^$1=$2\$" .env; }
for v in POSTGRES_PASSWORD ECOMMERCE_OWNER_PASSWORD ECOMMERCE_APP_PASSWORD INCIDENT_DB_PASSWORD \
  INCIDENT_OWNER_PASSWORD INCIDENT_APP_PASSWORD INCIDENT_API_TOKEN REDIS_PASSWORD GRAFANA_ADMIN_PASSWORD; do
  set_var "$v" "$(openssl rand -hex 24)"
done
# GitHub's Ubuntu runners use docker-ce: containerd's socket is in the stock place.
set_var CADVISOR_CONTAINERD_SOCKET /run/containerd/containerd.sock
set_var AWS_ACCOUNT_ID "${AWS_ACCOUNT_ID:-}"
rm -f .env.bak
echo "ci-env.sh: .env written"
