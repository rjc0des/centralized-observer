#!/usr/bin/env bash
# Restore both databases from a scripts/backup.sh backup, REPLACING their current contents:
#   scripts/restore.sh backups/<timestamp>
#   scripts/restore.sh s3://cop-aws-backups-<account>/backups/<timestamp>   (on the AWS host)
# The two APIs are stopped meanwhile (no writes between the drop and the reload). Each
# database is restored in one transaction: a failed restore leaves it as it was.
set -euo pipefail
cd "$(dirname "$0")/.."
die() { echo "restore.sh: $*" >&2; exit 1; }
src=${1:?usage: scripts/restore.sh <backup dir | s3://.../backups/<timestamp>>}

if [[ $src == s3://* ]]; then
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  aws s3 cp --recursive --only-show-errors "${src%/}/" "$tmp"
  src=$tmp
fi
for db in ecommerce incidents; do [ -s "$src/$db.dump" ] || die "$src/$db.dump missing or empty"; done

docker compose stop ecommerce-api incident-api
trap 'docker compose start ecommerce-api incident-api >/dev/null; rm -rf "${tmp:-}"' EXIT
for sd in postgres:ecommerce incident-db:incidents; do
  docker compose exec -T "${sd%:*}" pg_restore -U postgres -d "${sd#*:}" \
    --clean --if-exists --single-transaction --exit-on-error <"$src/${sd#*:}.dump"
  echo "restored ${sd#*:}" >&2
done
