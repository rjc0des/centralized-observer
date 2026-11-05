#!/usr/bin/env bash
# Backup/restore drill on the running stack: back up both databases, lose data (drop the
# order tables, delete marker rows), restore, then prove the data AND the runtime roles'
# grants came back (the API can place an order again). Stops both APIs for a few seconds.
set -uo pipefail
source "$(dirname "$0")/lib.sh"

IAPI=http://127.0.0.1:8081
sku="backup-test-$$"
title="backup-test-$$"
dir=backups/test-$$
psql_e() { docker compose exec -T postgres psql -U postgres -d ecommerce -tAq -v ON_ERROR_STOP=1 -c "$1"; }
psql_i() { docker compose exec -T incident-db psql -U postgres -d incidents -tAq -v ON_ERROR_STOP=1 -c "$1"; }
counts() { # one line per table: "<table> <rows>", both databases
  for t in products orders order_items schema_migrations; do echo "e.$t $(psql_e "SELECT count(*) FROM $t")"; done
  for t in incidents alerts events schema_migrations; do echo "i.$t $(psql_i "SELECT count(*) FROM $t")"; done
}
cleanup() {
  psql_e "DELETE FROM order_items WHERE product_id IN (SELECT id FROM products WHERE sku = '$sku');
          DELETE FROM orders o WHERE NOT EXISTS (SELECT 1 FROM order_items i WHERE i.order_id = o.id);
          DELETE FROM products WHERE sku = '$sku'" >/dev/null 2>&1
  psql_i "DELETE FROM incidents WHERE title = '$title'" >/dev/null 2>&1
  rm -rf "$dir"
  docker compose start ecommerce-api incident-api >/dev/null 2>&1
}
trap cleanup EXIT

echo "== Backup"
psql_e "INSERT INTO products (sku, name, price_cents, stock) VALUES ('$sku', 'Backup marker', 100, 5)" &&
  psql_i "INSERT INTO incidents (title, severity, environment, opened_at) VALUES ('$title', 'warning', 'backup-test', now())" ||
  { bad "could not insert marker rows"; finish; }
before=$(counts)
if scripts/backup.sh "$dir" >/dev/null && [ -s "$dir/ecommerce.dump" ] && [ -s "$dir/incidents.dump" ]; then
  pass "both databases dumped ($(du -sh "$dir" | cut -f1))"
else bad "backup failed"; finish; fi

echo "== Data loss"
psql_e "DROP TABLE order_items, orders; DELETE FROM products WHERE sku = '$sku'" >/dev/null &&
  psql_i "DELETE FROM incidents WHERE title = '$title'" >/dev/null
[ "$(psql_e "SELECT to_regclass('orders') IS NULL")" = t ] && pass "order tables dropped, marker rows deleted" || bad "data loss simulation failed"

echo "== Restore"
scripts/restore.sh "$dir" >/dev/null 2>&1 && pass "restore.sh completed" || bad "restore.sh failed"
after=$(counts)
# Exact for ecommerce; incident-api keeps receiving Alertmanager webhooks during the drill,
# so its tables may only have grown.
mismatch=$(paste -d' ' <(echo "$before") <(echo "$after") | awk '
  $1 ~ /^i\.(incidents|alerts|events)$/ { if ($4 < $2) print $1 "=" $2 "->" $4; next }
  $4 != $2 { print $1 "=" $2 "->" $4 }' | tr '\n' ' ')
[ -z "$mismatch" ] && pass "all 8 tables restored (ecommerce row counts exact)" || bad "row counts after restore: $mismatch"
[ "$(psql_e "SELECT stock FROM products WHERE sku = '$sku'")" = 5 ] && [ "$(psql_i "SELECT count(*) FROM incidents WHERE title = '$title'")" = 1 ] &&
  pass "marker product and marker incident are back" || bad "marker rows missing after restore"

echo "== Apps after restore"
retry 30 2 curl -fsS -o /dev/null "$APP/health" && retry 30 2 curl -fsS -o /dev/null "$IAPI/health" &&
  pass "both APIs healthy again" || bad "APIs not healthy after restore"
# The API's role (ecommerce_app) must have its grants back: an order touches all 3 tables.
pid=$(psql_e "SELECT id FROM products WHERE sku = '$sku'")
body=$(printf '{"items":[{"product_id":"%s","quantity":1}]}' "$pid")
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'content-type: application/json' -d "$body" "$APP/orders")
[ "$code" = 201 ] && [ "$(psql_e "SELECT stock FROM products WHERE sku = '$sku'")" = 4 ] &&
  pass "API placed an order on restored tables (app role grants restored)" || bad "POST /orders after restore: $code"
code=$(curl -s -o /dev/null -w '%{http_code}' "$IAPI/incidents")
[ "$code" = 200 ] && pass "incident API reads the restored database" || bad "GET /incidents after restore: $code"

finish
