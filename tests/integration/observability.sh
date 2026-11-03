#!/usr/bin/env bash
# Integration test for the running stack: metrics collection, log ingestion,
# log redaction and Grafana datasources. Needs `make up` first. Exit 1 on any failure.
set -uo pipefail
cd "$(dirname "$0")/../.."
[ -f .env ] && set -a && source .env && set +a

PROM=http://127.0.0.1:9090
LOKI=http://127.0.0.1:3100
GRAFANA=http://127.0.0.1:3000
PROBE_IMAGE=alpine:3.20@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc

fail=0
pass() { printf '  PASS  %s\n' "$*"; }
bad()  { printf '  FAIL  %s\n' "$*"; fail=1; }

# Number of series returned by a PromQL instant query.
prom_count() { curl -fsS -G "$PROM/api/v1/query" --data-urlencode "query=$1" | jq '.data.result | length'; }
# All log lines matching a LogQL query in the last 10 minutes, as JSON [{labels, line}].
loki_lines() {
  curl -fsS -G "$LOKI/loki/api/v1/query_range" --data-urlencode "query=$1" \
    --data-urlencode "start=$(( $(date +%s) - 600 ))000000000" --data-urlencode "limit=100" |
    jq -c '[.data.result[] | .stream as $s | .values[] | {labels: $s, line: .[1]}]'
}

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
[ "${probes:-0}" -gt 0 ] && [ -z "$failing" ] && pass "all $probes Blackbox HTTP probes succeed" || bad "probes failing: ${failing:-none collected}"

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

stack=$(loki_lines '{service="prometheus"}')
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

echo
[ $fail -eq 0 ] && echo "ALL PASSED" || echo "FAILURES ABOVE"
exit $fail
