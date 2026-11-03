#!/usr/bin/env bash
# Integration test for the running stack: metrics collection, log ingestion,
# log redaction and Grafana datasources. Needs `make up` first. Exit 1 on any failure.
set -uo pipefail
source "$(dirname "$0")/lib.sh"

echo "== Metrics"
# Targets need one scrape interval after startup; wait up to 60s for all to be up.
for _ in $(seq 1 12); do
  down=$(curl -fsS "$PROM/api/v1/targets?state=active" |
    jq -r '.data.activeTargets[] | select(.health != "up") | "\(.labels.job) \(.labels.instance) \(.lastError)"')
  [ -z "$down" ] && break
  sleep 5
done
total=$(curl -fsS "$PROM/api/v1/targets?state=active" | jq '.data.activeTargets | length')
[ -z "$down" ] && pass "all $total Prometheus targets up" || bad "targets down:"$'\n'"$down"

for q in \
  'node_cpu_seconds_total' \
  'node_memory_MemAvailable_bytes' \
  'node_filesystem_avail_bytes' \
  'node_network_receive_bytes_total' \
  'container_cpu_usage_seconds_total{container_label_com_docker_compose_project="cop"}' \
  'container_memory_working_set_bytes{container_label_com_docker_compose_project="cop"}' \
  'loki_build_info' \
  'alloy_build_info'; do
  n=$(prom_count "$q")
  [ "${n:-0}" -gt 0 ] && pass "$q ($n series)" || bad "$q returned no series"
done

# A probe that ran while a service was still starting reads 0 until the next 15s probe.
for _ in $(seq 1 12); do
  failing=$(curl -fsS -G "$PROM/api/v1/query" --data-urlencode 'query=probe_success == 0' | jq -r '.data.result[].metric.instance')
  [ -z "$failing" ] && break
  sleep 5
done
probes=$(prom_count 'probe_success')
[ "${probes:-0}" -gt 0 ] && [ -z "$failing" ] && pass "all $probes Blackbox probes succeed (HTTP + TCP)" || bad "probes failing: ${failing:-none collected}"

echo "== Logs"
marker="cop-test-$(date +%s)-$RANDOM"
# A throwaway container in this compose project, so Alloy discovers it like any service.
docker run -d --rm --name "cop-logprobe-$marker" \
  --label com.docker.compose.project=cop --label com.docker.compose.service=log-probe \
  "$PROBE_IMAGE" sh -c "
    echo '{\"level\":\"ERROR\",\"msg\":\"$marker tag-jsonerr\",\"password\":\"hunter2\",\"trace_id\":\"trace-$marker\"}'
    echo 'level=warn msg=\"$marker tag-logfmt\" token=s3cr3t-value'
    echo '$marker tag-bearer Authorization: Bearer eyJhbGciOi.abc.def'
    echo '{\"level\":\"WARNING\",\"msg\":\"$marker tag-jsonwarning\"}'
    echo '$marker tag-noise battery level=Overcharged'
    sleep 60" >/dev/null

lines='[]'
for _ in $(seq 1 15); do
  lines=$(loki_lines "{service=\"log-probe\"} |= \"$marker\"")
  [ "$(jq length <<<"$lines")" -ge 5 ] && break
  sleep 3
done
docker rm -f "cop-logprobe-$marker" >/dev/null 2>&1

# Level label of the test line carrying the given tag ("null" if no label).
level_of() { jq -r --arg t "$1" '[.[] | select(.line | contains($t)) | .labels.level][0]' <<<"$lines"; }

n=$(jq length <<<"$lines")
[ "$n" -eq 5 ] && pass "5/5 test log lines ingested into Loki" || bad "expected 5 log lines in Loki, got $n"

all=$(jq -r '.[].line' <<<"$lines")
if grep -qE 'hunter2|s3cr3t-value|eyJhbGciOi' <<<"$all"; then bad "secrets leaked into Loki:"$'\n'"$all"
else [ "$(grep -c '\[REDACTED\]' <<<"$all")" -eq 3 ] && pass "password, token and bearer token redacted" || bad "redaction marker missing:"$'\n'"$all"; fi

[ "$(jq -r '[.[].labels.environment] | unique | join(",")' <<<"$lines")" = "${ENVIRONMENT:-local}" ] \
  && pass "environment label = ${ENVIRONMENT:-local}" || bad "environment label wrong: $(jq -c '[.[].labels.environment]|unique' <<<"$lines")"

[ "$(level_of tag-jsonerr)" = error ] && pass "JSON level parsed and lowercased (ERROR -> error)" || bad "JSON level: '$(level_of tag-jsonerr)', want error"
[ "$(level_of tag-logfmt)" = warn ] && pass "logfmt level parsed (warn)" || bad "logfmt level: '$(level_of tag-logfmt)', want warn"
[ "$(level_of tag-jsonwarning)" = warn ] && pass "level normalised (WARNING -> warn)" || bad "WARNING level: '$(level_of tag-jsonwarning)', want warn"
[ "$(level_of tag-noise)" = null ] && pass "unknown level ('Overcharged') gets no label" || bad "free text became a level label: '$(level_of tag-noise)'"

tid=$(jq length <<<"$(loki_lines "{service=\"log-probe\"} | trace_id=\"trace-$marker\"")")
[ "$tid" -eq 1 ] && pass "trace_id stored as structured metadata (not a label)" || bad "trace_id metadata query returned $tid lines"
# Query responses merge structured metadata into labels, so check Loki's index label names.
curl -fsS "$LOKI/loki/api/v1/labels" | jq -e '.data | index("trace_id") | not' >/dev/null \
  && pass "trace_id is not an index label" || bad "trace_id became an index label (unbounded cardinality)"

# Prometheus logs mostly at startup, so look back to when its container started.
started=$(docker inspect cop-prometheus-1 | jq -r '.[0].State.StartedAt | sub("\\..*"; "Z") | fromdate')
stack=$(loki_lines '{service="prometheus"}' "$started")
[ "$(jq length <<<"$stack")" -gt 0 ] && pass "stack container logs collected (service=prometheus)" || bad "no logs from prometheus container"

echo "== Grafana"
auth=(-u "${GRAFANA_ADMIN_USER:-admin}:${GRAFANA_ADMIN_PASSWORD:-}")
for uid in prometheus loki; do
  status=$(curl -fsS "${auth[@]}" "$GRAFANA/api/datasources/uid/$uid/health" 2>/dev/null | jq -r '.status')
  [ "$status" = OK ] && pass "datasource $uid healthy" || bad "datasource $uid health: ${status:-request failed}"
done
# The Alertmanager datasource has no health endpoint; query Alertmanager through Grafana's proxy.
uptime=$(curl -fsS "${auth[@]}" "$GRAFANA/api/datasources/proxy/uid/alertmanager/api/v2/status" 2>/dev/null | jq -r '.uptime // empty')
[ -n "$uptime" ] && pass "datasource alertmanager reachable via Grafana proxy" || bad "datasource alertmanager: request failed"

echo "== Dashboards"
# Labelled app counters only exist after the first request, and a cold-started API has
# served none. Browse, order and look the order up, then wait until rate() sees it.
kb=$(curl -fsS "$APP/products" | jq -r '.products[] | select(.sku == "KB-001") | .id'); curl -fsS -o /dev/null "$APP/products"
body=$(printf '{"items":[{"product_id":"%s","quantity":1}]}' "$kb")
oid=$(curl -fsS -X POST "$APP/orders" -H 'content-type: application/json' -d "$body" | jq -r .id)
curl -fsS -o /dev/null "$APP/orders/$oid"
# A new counter starts at 1, so its rate is 0: wait for the series, not for rate > 0.
app_rates() { [ "$(prom_count 'rate(orders_total{service="ecommerce-api"}[1m])')" -gt 0 ]; }
retry 12 5 app_rates || bad "shop requests never showed up in Prometheus; app panels would be empty"
# The 30-day SLO rules run once a minute; right after a restart they may not have yet.
slo_budgets() { [ "$(prom_count 'slo:error_ratio:rate30d')" -ge 3 ]; }
retry 15 5 slo_budgets || bad "30-day SLO ratios not recorded after 75s"
# Every panel query must parse and return data: a typo in a metric name doesn't error,
# it just draws an empty panel. Panels documented "Empty when healthy." may be empty.
# Grafana variables are replaced with what they expand to (all environments, 1m steps).
panel_queries() { jq -r '.panels[] | select(.targets) | . as $p | .targets[] |
  [$p.datasource.uid, ($p.description // "" | contains("Empty when healthy.")), $p.title,
   (.expr | gsub("\\$environment"; ".*") | gsub("\\$__rate_interval|\\$__auto"; "1m"))] | @tsv' "$1"; }
query_result() { # <datasource uid> <expr>: prints "error", or the number of series returned
  if [ "$1" = loki ]; then curl -sS -G "$LOKI/loki/api/v1/query_range" --data-urlencode "query=$2" --data-urlencode "since=1h"
  else curl -sS -G "$PROM/api/v1/query" --data-urlencode "query=$2"; fi | jq -r 'if .status == "success" then .data.result | length else "error" end' 2>/dev/null || echo error; }
for f in observability/grafana/provisioning/dashboards/*.json; do
  uid=$(jq -r .uid "$f"); title=$(jq -r .title "$f")
  [ "$(curl -fsS "${auth[@]}" "$GRAFANA/api/dashboards/uid/$uid" 2>/dev/null | jq -r .dashboard.title)" = "$title" ] \
    || { bad "dashboard $uid not provisioned in Grafana"; continue; }
  total=0 failed=0
  while IFS=$'\t' read -r ds empty_ok ptitle expr; do
    total=$((total + 1)); n=$(query_result "$ds" "$expr")
    why=; [ "$n" = error ] && why="query error"; [ "$n" = 0 ] && [ "$empty_ok" = false ] && why="no data"
    [ -n "$why" ] && { failed=$((failed + 1)); bad "$uid / $ptitle: $why for: $expr"; }
  done <<<"$(panel_queries "$f")"
  [ "$failed" -eq 0 ] && pass "dashboard $uid provisioned, all $total queries valid and returning data"
done

finish
