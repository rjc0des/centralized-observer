#!/usr/bin/env bash
# Failure drill: break one component, then time what the platform does about it:
# alert firing (Alertmanager) -> incident opened (incident API) -> component back ->
# alert resolved -> incident resolved.
#   scripts/simulate.sh app-down | db-down | redis-down | loki-down
# Takes 3-10 minutes (alert `for:` windows and Alertmanager group intervals). Runs locally
# or on the AWS host: scripts/aws.sh run '/opt/cop/current/scripts/simulate.sh db-down'
# Configured email/Slack receivers ARE notified: a drill exercises the real paging path.
set -euo pipefail
cd "$(dirname "$0")/.."
AM=http://127.0.0.1:9093
IAPI=http://127.0.0.1:8081

case ${1:-} in
  app-down) svc=ecommerce-api alert=ApplicationDown match='service="ecommerce-api"' ;;
  db-down) svc=postgres alert=DatabaseUnavailable match= ;;
  redis-down) svc=redis alert=RedisUnavailable match= ;;
  loki-down) svc=loki alert=EndpointDown match='instance="http://loki:3100/ready"' ;;
  *) echo "usage: $0 app-down|db-down|redis-down|loki-down" >&2; exit 2 ;;
esac

# Matching alerts Alertmanager has active and would notify about (not silenced/inhibited).
active() {
  curl -fsS -G "$AM/api/v2/alerts" --data-urlencode "filter=alertname=\"$alert\"" ${match:+--data-urlencode "filter=$match"} \
    --data-urlencode active=true --data-urlencode silenced=false --data-urlencode inhibited=false | jq length
}
# "<id> <status>" of the newest incident that lists this alert, optionally unresolved only.
incident() {
  curl -fsS "$IAPI/incidents?limit=100" | jq -r --arg a "$alert" --arg st "${1:-any}" \
    '[.[] | select((.alertnames | any(. == $a)) and ($st == "any" or .status != "resolved"))] | max_by(.id) // empty | "\(.id) \(.status)"'
}
t0=$(date +%s)
wait_for() { # wait_for <what> <command...>: poll every 5s for up to 10 minutes
  local what=$1
  shift
  for _ in $(seq 1 120); do
    if "$@"; then printf '  +%4ss  %s\n' $(($(date +%s) - t0)) "$what"; return 0; fi
    sleep 5
  done
  printf '  +%4ss  TIMEOUT: %s\n' $(($(date +%s) - t0)) "$what" >&2
  return 1
}

[ "$(active)" = 0 ] || { echo "simulate.sh: $alert is already firing; a drill needs a quiet start" >&2; exit 1; }
[ -z "$(incident unresolved)" ] || { echo "simulate.sh: incident $(incident unresolved) still lists $alert; resolve it first" >&2; exit 1; }

trap 'docker compose start "$svc" >/dev/null 2>&1' EXIT
echo "== $1: stopping $svc"
docker compose stop "$svc" >/dev/null 2>&1
t0=$(date +%s)
wait_for "$alert firing in Alertmanager" eval '[ "$(active)" -gt 0 ]'
wait_for "incident opened" eval '[ -n "$(incident unresolved)" ]'
id=$(incident unresolved | cut -d' ' -f1)
echo "     incident $id: $IAPI/incidents/$id"

echo "== starting $svc"
docker compose start "$svc" >/dev/null 2>&1
t0=$(date +%s)
wait_for "$alert resolved in Alertmanager" eval '[ "$(active)" = 0 ]'
wait_for "incident $id resolved" eval '[ "$(incident | cut -d" " -f2)" = resolved ]'
echo "== report: $IAPI/incidents/$id/report"
