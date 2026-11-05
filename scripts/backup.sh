#!/usr/bin/env bash
# Logical backups of both databases: ecommerce (postgres) and incidents (incident-db),
# pg_dump custom format (compressed; includes ownership and grants). Online: no downtime.
#   scripts/backup.sh [dir]     default backups/<UTC timestamp> (git-ignored); prints the dir
# With BACKUP_S3 set (the AWS host's .env, run daily by cop-backup.timer) the dumps are also
# copied to $BACKUP_S3/<timestamp>/ (versioned bucket; the host role can't delete objects).
# Not backed up: Prometheus and Loki data (re-collected; 30d / 72h retention) and Grafana
# (provisioned from Git). Restore: scripts/restore.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
BACKUP_S3=$(sed -n 's/^BACKUP_S3=//p' .env 2>/dev/null | tail -1)

ts=$(date -u +%Y%m%dT%H%M%SZ)
dir=${1:-backups/$ts}
umask 077
mkdir -p "$dir"
# service database: superuser over the container's local socket (no password leaves it).
for sd in postgres:ecommerce incident-db:incidents; do
  docker compose exec -T "${sd%:*}" pg_dump -U postgres -Fc "${sd#*:}" >"$dir/${sd#*:}.dump"
  # A truncated dump fails to list; catch it now, not at restore time.
  docker compose exec -T "${sd%:*}" pg_restore --list <"$dir/${sd#*:}.dump" >/dev/null
done
if [ -n "$BACKUP_S3" ]; then
  aws s3 cp --recursive --only-show-errors "$dir" "$BACKUP_S3/$ts/"
  echo "uploaded to $BACKUP_S3/$ts/" >&2
fi
echo "$dir"
