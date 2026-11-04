#!/usr/bin/env bash
# Integration test for the e-commerce API on the running stack: endpoints, stock
# consistency under concurrency, metrics, trace-correlated logs, and a Redis outage.
# Needs `make up` first. Briefly stops and restarts the redis container. Exit 1 on failure.
#
# Note: macOS ships bash 3.2, which mis-parses "$(cmd "...\"...\"...")". Queries and
# JSON bodies are therefore built in variables/functions, never inline with \".
set -uo pipefail
source "$(dirname "$0")/lib.sh"

# Always bring Redis back, even if the script is interrupted mid-outage.
trap 'docker compose start redis >/dev/null 2>&1' EXIT

UUID_RE='[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
SVC='service="ecommerce-api"'

# psql as the API's runtime role. Statements run inside BEGIN/ROLLBACK, so even a
# wrongly granted DROP or DELETE would be undone.
psql_app() { docker compose exec -T -e PGPASSWORD="$ECOMMERCE_APP_PASSWORD" postgres \
  psql -h 127.0.0.1 -U ecommerce_app -d "${2:-ecommerce}" -tAq -v ON_ERROR_STOP=1 -c 'BEGIN' -c "$1" -c 'ROLLBACK' 2>&1; }
psql_ecommerce() { psql_app "$1"; }
# psql as the owner role (commits). Used only to set up test fixtures.
psql_owner() { docker compose exec -T -e PGPASSWORD="$ECOMMERCE_OWNER_PASSWORD" postgres \
  psql -h 127.0.0.1 -U ecommerce_owner -d "${2:-ecommerce}" -tAq -v ON_ERROR_STOP=1 -c "$1" 2>&1; }
codes_for() { # codes_for <n> <json-body>: fire n concurrent orders, print status codes
  local body=$2; seq 1 "$1" | xargs -P "$1" -I{} curl -s -o /dev/null -w '%{http_code}\n' -X POST "$APP/orders" \
    -H 'content-type: application/json' -d "$body"; }
app_metric() { curl -s "$APP/metrics" | awk -v m="$1" '$1==m {print $2}'; }
order_body() { printf '{"items":[{"product_id":"%s","quantity":%d}]}' "$1" "$2"; }
post_order() { curl -s -X POST "$APP/orders" -H 'content-type: application/json' -d "$1"; }
post_status() { curl -s -o /dev/null -w '%{http_code}' -X POST "$APP/orders" -H 'content-type: application/json' -d "$1"; }
get_status() { curl -s -o /dev/null -w '%{http_code}' "$1"; }
x_cache() { curl -s -D- -o /dev/null "$APP/products" | tr -d '\r' | awk -F': ' 'tolower($1)=="x-cache"{print $2}'; }

echo "== Image provenance"
# cop/ecommerce-api and cop/incident-api are local-only names ("cop" is unclaimed on Docker Hub). It must be
# built, never pulled: the migrate jobs run them with the database owner passwords.
policies=$(docker compose config --format json | jq -r '[.services | to_entries[] | select(.value.image // "" | startswith("cop/")) | "\(.key)=\(.value.pull_policy)"] | sort | join(" ")')
[ "$policies" = "ecommerce-api=build ecommerce-migrate=never incident-api=build incident-migrate=never" ] \
  && pass "local images never pulled from a registry ($policies)" || bad "unsafe pull policies: $policies"
# During first-boot init Postgres listens on its Unix socket only; the healthcheck must
# test TCP (what clients use), or the migrate job can start too early.
docker compose config --format json | jq -e '.services.postgres.healthcheck.test | index("127.0.0.1")' >/dev/null \
  && pass "postgres healthcheck tests TCP (-h 127.0.0.1), not the init-time Unix socket" || bad "postgres healthcheck does not test TCP"

echo "== Startup"
# A healthy restart must not log a dependency failure (regression: the first check
# once ran before the Redis client had connected, logging a false outage every start).
restart_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
docker compose restart ecommerce-api >/dev/null 2>&1
health_ok() { [ "$(curl -s "$APP/health" | jq -r .status 2>/dev/null)" = ok ]; }
retry 20 1 health_ok || bad "ecommerce-api not healthy after restart"
false_alarms=$(docker compose logs --since "$restart_at" ecommerce-api 2>&1 | grep -c 'connection failed')
[ "$false_alarms" -eq 0 ] && pass "clean restart logs no dependency failures" || bad "clean restart logged $false_alarms 'connection failed' line(s)"

echo "== API"
health=$(curl -fsS "$APP/health")
[ "$(jq -r .status <<<"$health")" = ok ] && pass "/health ok (postgres up, redis up)" || bad "/health: $health"

docker compose exec -T redis redis-cli del products:v1 >/dev/null
c1=$(x_cache); c2=$(x_cache)
[ "$c1 $c2" = "miss hit" ] && pass "/products: cache miss then hit" || bad "/products cache sequence: '$c1 $c2', want 'miss hit'"

products=$(curl -fsS "$APP/products")
KB=$(jq -r '.products[] | select(.sku=="KB-001") | .id' <<<"$products")
LIMITED=$(jq -r '.products[] | select(.sku=="LIMITED-001") | .id' <<<"$products")

order=$(post_order "$(order_body "$KB" 2)")
oid=$(jq -r '.id // empty' <<<"$order")
if [ -n "$oid" ] && [ "$(jq -r '.total_cents | type' <<<"$order")" = number ] && [ "$(jq .total_cents <<<"$order")" -eq 17998 ]; then
  pass "POST /orders -> 201, total_cents is a number (17998)"
else bad "POST /orders: $order"; fi
fetched=$(curl -fsS "$APP/orders/$oid")
[ "$(jq -r .id <<<"$fetched")" = "$oid" ] && [ "$(jq '.items[0].quantity' <<<"$fetched")" -eq 2 ] \
  && pass "GET /orders/:id returns the order with its items" || bad "GET /orders/$oid: $fetched"

s=$(post_status "$(order_body "$LIMITED" 100)"); [ "$s" = 409 ] && pass "out of stock -> 409" || bad "out-of-stock order returned $s"
s=$(post_status "$(order_body 00000000-0000-7000-8000-000000000000 1)"); [ "$s" = 422 ] && pass "unknown product -> 422" || bad "unknown product returned $s"
s=$(post_status '{"items":"nope"}'); [ "$s" = 400 ] && pass "invalid body -> 400" || bad "invalid body returned $s"
s1=$(get_status "$APP/orders/00000000-0000-7000-8000-000000000000"); s2=$(get_status "$APP/orders/not-a-uuid")
[ "$s1 $s2" = "404 400" ] && pass "unknown order -> 404, malformed id -> 400" || bad "order lookups returned '$s1 $s2', want '404 400'"

echo "== Stock consistency"
before=$(psql_ecommerce "SELECT stock FROM products WHERE id = '$KB'")
created=$(codes_for 20 "$(order_body "$KB" 1)" | grep -c '^201$')
after=$(psql_ecommerce "SELECT stock FROM products WHERE id = '$KB'")
[ "$created" -eq 20 ] && [ $((before - after)) -eq 20 ] \
  && pass "20 concurrent orders on ample stock: 20 created, stock -20 ($before -> $after)" \
  || bad "created=$created, stock $before -> $after (want 20 and -20)"

# Contention on scarce stock is what the row lock is for: 10 buyers race for 5 units.
# With FOR UPDATE, losers get a clean 409. Without it, the CHECK (stock >= 0) constraint
# would still prevent overselling, but losers would get 500s, which this catches.
psql_owner "UPDATE products SET stock = 5 WHERE id = '$LIMITED'" >/dev/null
codes=$(codes_for 10 "$(order_body "$LIMITED" 1)" | sort | uniq -c | awk '{printf "%s×%s ", $1, $2}')
left=$(psql_ecommerce "SELECT stock FROM products WHERE id = '$LIMITED'")
psql_owner "UPDATE products SET stock = 5 WHERE id = '$LIMITED'" >/dev/null # reset fixture
[ "$codes" = "5×201 5×409 " ] && [ "$left" = 0 ] \
  && pass "10 concurrent buyers for 5 units: 5×201, 5×409, no 500s, stock 0" \
  || bad "scarce-stock race: ${codes}stock left $left (want 5×201 5×409, 0)"

echo "== Database least privilege (runtime role ecommerce_app)"
denied() { grep -qE 'permission denied|must be owner|not have CONNECT privilege' <<<"$1"; }
for sql in \
  'UPDATE products SET price_cents = 0' \
  'DELETE FROM orders' \
  'UPDATE orders SET total_cents = 0' \
  'DROP TABLE orders' \
  'ALTER TABLE products ADD COLUMN x int' \
  'CREATE TABLE intruder (id int)' \
  'SELECT * FROM schema_migrations'; do
  out=$(psql_app "$sql")
  denied "$out" && pass "denied: $sql" || bad "ALLOWED (should be denied): $sql -> $out"
done
for db in postgres template1; do
  out=$(psql_app 'SELECT 1' "$db")
  denied "$out" && pass "denied: connect to $db database" || bad "ecommerce_app can connect to $db: $out"
done
for db in postgres template1; do
  out=$(psql_owner 'SELECT 1' "$db")
  denied "$out" && pass "denied: ecommerce_owner connect to $db database" || bad "ecommerce_owner can connect to $db: $out"
done
out=$(psql_app "SELECT count(*) FROM products")
[[ "$out" =~ ^[0-9]+$ ]] && pass "allowed: read products ($out rows)" || bad "ecommerce_app cannot read products: $out"

echo "== Saturation: a busy pool is not 'Postgres down'"
# Hold a row lock for 4s, then send 15 orders for that product. 10 take every request-pool
# connection and wait on the lock; 5 can't get a connection within 2s (POOL_TIMEOUT 500s).
# Postgres itself is fine the whole time, and /health must say so.
# Side effect: 5 deliberate 5xx and POOL_TIMEOUT exceptions in this run's metrics.
saturation_start=$(date +%s)
psql_owner "BEGIN; SELECT 1 FROM products WHERE id = '$KB' FOR UPDATE; SELECT pg_sleep(4); COMMIT;" >/dev/null &
lock_pid=$!
sleep 0.5
codes_for 15 "$(order_body "$KB" 1)" >/dev/null &
orders_pid=$!
sleep 1 # inside the 2s pool timeout: 10 connections busy, 5 orders queued for one
waiting=$(app_metric 'db_pool_connections{state="waiting"}'); idle=$(app_metric 'db_pool_connections{state="idle"}')
h=$(curl -s -m 3 "$APP/health"); pg_gauge=$(app_metric 'dependency_up{dependency="postgres"}')
wait $lock_pid $orders_pid
if [ "${waiting:-0}" -gt 0 ] && [ "$idle" = 0 ]; then
  [ "$(jq -r .checks.postgres <<<"$h")" = up ] && [ "$pg_gauge" = 1 ] \
    && pass "pool saturated (idle=0, waiting=$waiting) yet /health postgres=up, dependency_up=1" \
    || bad "saturated pool misreported as Postgres down: health=$h dependency_up=$pg_gauge"
else bad "test did not saturate the pool (idle=$idle waiting=$waiting); result would be meaningless"; fi
pt=$(app_metric 'app_exceptions_total{type="POOL_TIMEOUT"}')
[ "${pt:-0}" -gt 0 ] && pass "pool exhaustion counted as app_exceptions_total{type=POOL_TIMEOUT} ($pt)" || bad "no POOL_TIMEOUT exceptions recorded"
sleep 6 # one more poller cycle after the lock is released
loki_has "{$SVC} |= \"postgres connection failed\"" "$saturation_start" \
  && bad "a 'postgres connection failed' line was logged during saturation" || pass "no false 'postgres connection failed' logged"

echo "== Diagnostics: Redis failure cause, stray containers"
# A throwaway API container with a wrong Redis password, not started by Compose.
probe="probe-redis-auth-$$"
docker run -d --rm --name "$probe" --network cop_default \
  -e PGHOST=postgres -e PGDATABASE=ecommerce -e PGUSER=ecommerce_app -e PGPASSWORD="$ECOMMERCE_APP_PASSWORD" \
  -e REDIS_URL=redis://redis:6379 -e REDIS_PASSWORD=deliberately-wrong cop/ecommerce-api:dev >/dev/null
redis_cause() { docker logs "$probe" 2>&1 | grep 'redis connection failed' | grep -q WRONGPASS; }
retry 10 1 redis_cause && pass "Redis auth failure logged with its cause (WRONGPASS), not just 'client is offline'" \
  || bad "redis failure log lacks the cause: $(docker logs "$probe" 2>&1 | grep 'redis connection failed' | head -1 | cut -c1-200)"
# The probe uses the Compose-built image, so it carries the project/service labels and
# would pass Alloy's project filter. Only the container-name rule keeps it out. A control
# container that IS eligible (cop-* name) proves Alloy had time to discover both.
control="cop-logcontrol-$$"
docker run -d --rm --name "$control" --label com.docker.compose.project=cop \
  --label com.docker.compose.service=log-control "$PROBE_IMAGE" sh -c 'while true; do echo control; sleep 1; done' >/dev/null
retry 30 3 loki_has "{container=\"$control\"}" || bad "control container never reached Loki; stray check would be meaningless"
docker rm -f "$probe" "$control" >/dev/null 2>&1
loki_has "{container=\"$probe\"}" && bad "stray container $probe was ingested into Loki" \
  || pass "containers not started by Compose are not ingested (control $control was)"

echo "== Metrics"
retry 8 5 prom_is "up{job=\"apps\",$SVC}" 1 && pass "Prometheus scrapes ecommerce-api (job=apps, up=1)" || bad "ecommerce-api target not up"

# Wait for a scrape that includes the requests made above.
retry 8 5 prom_is "clamp_max(count(http_requests_total{$SVC,route=\"/orders/:id\"}), 1)" 1
routes=$(curl -fsS -G "$PROM/api/v1/query" --data-urlencode "query=count by (route) (http_requests_total{$SVC})" | jq -r '[.data.result[].metric.route] | sort | join(",")')
unexpected=$(tr ',' '\n' <<<"$routes" | grep -vxE '/products|/orders|/orders/:id|unmatched' || true)
[ -n "$routes" ] && [ -z "$unexpected" ] && pass "route labels are templates only: $routes" || bad "unexpected route labels: ${unexpected:-none collected}"

leaked=$(for l in route method status_code type result dependency state; do
  curl -fsS "$PROM/api/v1/label/$l/values" | jq -r '.data[]'; done | grep -E "$UUID_RE" || true)
[ -z "$leaked" ] && pass "no UUID appears in any app label value" || bad "IDs leaked into labels: $leaked"

for q in \
  "http_request_duration_seconds_bucket{$SVC,le=\"0.5\"}" \
  "http_requests_in_flight{$SVC}" \
  "db_pool_connections{$SVC,state=\"total\"}" \
  "orders_total{$SVC,result=\"created\"}" \
  "cache_requests_total{$SVC,result=\"hit\"}" \
  "nodejs_eventloop_lag_seconds{$SVC}"; do
  [ "$(prom_count "$q")" -gt 0 ] && pass "$q" || bad "$q returned no series"
done
for dep in postgres redis; do
  prom_is "dependency_up{$SVC,dependency=\"$dep\"}" 1 && pass "dependency_up{dependency=$dep} = 1" || bad "dependency_up{$dep} != 1"
done
# count(... == 1) = 3 also proves all three probes exist (min() alone would pass with one).
probes='probe_success{instance=~"http://ecommerce-api:3000/health|postgres:5432|redis:6379"}'
retry 8 5 prom_is "count($probes == 1)" 3 \
  && pass "Blackbox: /health HTTP probe + postgres/redis TCP probes all succeed (3/3)" \
  || bad "Blackbox app/dependency probes: $(prom_value "count($probes == 1)" || echo 0)/3 succeeding"

echo "== Logs"
trace_id=$(openssl rand -hex 16)
curl -fsS -o /dev/null -H "traceparent: 00-$trace_id-$(openssl rand -hex 8)-01" \
  -H 'Authorization: Bearer cop-secret-token-xyz' "$APP/orders/$oid"
by_trace="{$SVC} | trace_id=\"$trace_id\""
retry 10 3 loki_has "$by_trace" && pass "incoming traceparent continued: log line found in Loki by trace_id" || bad "no log line with trace_id=$trace_id"

line=$(loki_lines "$by_trace" | jq -r '.[0].line')
missing=$(jq -r '[ "time","level","service","environment","msg","trace_id" ] - (keys) | join(",")' <<<"$line" 2>/dev/null)
[ -z "$missing" ] && [ "$(jq -r .route <<<"$line")" = "/orders/:id" ] && pass "log line has time, level, service, environment, msg, trace_id, route" \
  || bad "log fields missing: ${missing:-?} in $line"

docker compose logs ecommerce-api 2>&1 | grep -q 'cop-secret-token-xyz' \
  && bad "Authorization header value found in raw container logs" || pass "Authorization header never logged (raw container logs checked)"

echo "== Redis outage"
outage_start=$(date +%s)  # only count log lines written after this
docker compose stop redis >/dev/null 2>&1
h=$(curl -s "$APP/health")
[ "$(jq -r '.status + "/" + .checks.redis' <<<"$h")" = degraded/down ] && pass "/health -> 200 degraded (redis down)" || bad "/health during outage: $h"
p=$(curl -s -D- -o /dev/null "$APP/products" | tr -d '\r')
grep -q '^HTTP/1.1 200' <<<"$p" && grep -qi '^x-cache: bypass' <<<"$p" && pass "/products still 200, served from Postgres (x-cache: bypass)" || bad "/products during outage: $(head -1 <<<"$p")"
redis_up="dependency_up{$SVC,dependency=\"redis\"}"
retry 10 4 prom_is "$redis_up" 0 && pass "dependency_up{redis} = 0 in Prometheus" || bad "dependency_up{redis} did not drop to 0"
retry 10 3 loki_has "{$SVC,level=\"error\"} |= \"redis connection failed\"" "$outage_start" && pass "Loki: level=error 'redis connection failed' logged during this outage" || bad "no 'redis connection failed' error log in Loki"

docker compose start redis >/dev/null 2>&1
retry 15 2 health_ok && pass "recovered: /health ok after Redis restart" || bad "/health not ok after Redis restart"
retry 10 4 prom_is "$redis_up" 1 && pass "dependency_up{redis} back to 1" || bad "dependency_up{redis} did not recover"
retry 10 3 loki_has "{$SVC} |= \"redis connection recovered\"" "$outage_start" && pass "Loki: 'redis connection recovered' logged after this outage" || bad "no recovery log in Loki"

finish
