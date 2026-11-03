# Shared helpers for integration tests. Source it; don't run it.
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1
[ -f .env ] && set -a && source .env && set +a

PROM=http://127.0.0.1:9090
LOKI=http://127.0.0.1:3100
GRAFANA=http://127.0.0.1:3000
APP=http://127.0.0.1:8080
PROBE_IMAGE=alpine:3.20@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc

fail=0
pass() { printf '  PASS  %s\n' "$*"; }
bad()  { printf '  FAIL  %s\n' "$*"; fail=1; }
finish() { echo; [ $fail -eq 0 ] && echo "ALL PASSED" || echo "FAILURES ABOVE"; exit $fail; }

# retry <attempts> <sleep-seconds> <command...>: rerun until it succeeds.
retry() { local n=$1 s=$2; shift 2; for _ in $(seq 1 "$n"); do "$@" && return 0; sleep "$s"; done; return 1; }

# Number of series returned by a PromQL instant query.
prom_count() { curl -fsS -G "$PROM/api/v1/query" --data-urlencode "query=$1" | jq '.data.result | length'; }
# Value of the first series of a PromQL instant query (empty if none).
prom_value() { curl -fsS -G "$PROM/api/v1/query" --data-urlencode "query=$1" | jq -r '.data.result[0].value[1] // empty'; }

# prom_is <query> <expected>: first series value equals expected (use with retry).
prom_is() { [ "$(prom_value "$1")" = "$2" ]; }
# loki_has <logql> [since-epoch-seconds]: at least one matching line (use with retry).
loki_has() { [ "$(loki_lines "$1" "${2:-}" | jq length)" -gt 0 ]; }

# Log lines matching a LogQL query, as JSON [{labels, line}]. Window starts at the
# optional epoch-seconds argument, else 10 minutes ago.
loki_lines() {
  curl -fsS -G "$LOKI/loki/api/v1/query_range" --data-urlencode "query=$1" \
    --data-urlencode "start=${2:-$(( $(date +%s) - 600 ))}000000000" --data-urlencode "limit=100" |
    jq -c '[.data.result[] | .stream as $s | .values[] | {labels: $s, line: .[1]}]'
}
