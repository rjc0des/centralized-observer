#!/usr/bin/env bash
# Integration test for alerting on the running stack: rules loaded, Alertmanager
# routing and inhibition, and one real outage end to end (Postgres stopped ->
# DatabaseUnavailable -> webhook, Slack-format and email -> recovery notifications).
# Needs `make up` first. Stops Postgres for about 2-3 minutes; takes ~4 minutes.
# The outage is skipped (SKIP, not PASS) when real email/Slack receivers are configured:
# it would page people. Rule logic itself is unit-tested by promtool (make unit).
set -uo pipefail
source "$(dirname "$0")/lib.sh"

AM=http://127.0.0.1:9093
MAILPIT=http://127.0.0.1:8025
trap 'docker compose start postgres >/dev/null 2>&1' EXIT

# Alertmanager counts failed sends (e.g. a receiver answering with an error); a
# delivery test that only looks at the receiver would miss them.
am_failures() { curl -fsS "$AM/metrics" | awk '/^alertmanager_notifications_failed_total/ {n += $2} END {print n + 0}'; }
failures_before=$(am_failures)

echo "== Rules"
rules=$(curl -fsS "$PROM/api/v1/rules")
unhealthy=$(jq -r '[.data.groups[].rules[] | select(.health != "ok") | "\(.name): \(.lastError)"] | join("; ")' <<<"$rules")
[ -z "$unhealthy" ] && pass "all $(jq '[.data.groups[].rules[]] | length' <<<"$rules") rules evaluate without errors" || bad "rule errors: $unhealthy"
expected="ApplicationDown ContainerRestarting DatabaseUnavailable DiskSpaceLow EndpointDown ErrorBudgetFastBurn ErrorBudgetSlowBurn HighCPUUsage HighHTTPErrorRate HighMemoryUsage HighRequestLatency InstanceDown LokiIngestionFailure MonitoringStoragePressure PrometheusTargetMissing RedisUnavailable"
loaded=$(jq -r '[.data.groups[].rules[] | select(.type == "alerting") | .name] | unique | join(" ")' <<<"$rules")
[ "$loaded" = "$expected" ] && pass "16 alerts loaded (13 required + EndpointDown + 2 SLO burn-rate)" || bad "alerts loaded: $loaded"
recorded=$(prom_count 'slo:error_ratio:rate5m')
[ "${recorded:-0}" -ge 3 ] && pass "SLO error ratios recorded ($recorded series)" || bad "slo:error_ratio:rate5m has ${recorded:-0} series, want availability, latency, freshness"

echo "== Routing and inhibition (synthetic alerts)"
# Alerts posted straight to Alertmanager, in a throwaway environment. They are resolved
# before group_wait (30s) ends, so no notification is sent for them.
env="routing-test-$$"
batch=
add_alert() { # add_alert <alertname> <severity> [extra JSON labels]
  batch="${batch:+$batch,}$(printf '{"labels":{"alertname":"%s","severity":"%s","environment":"%s","job":"test","instance":"i1"%s}}' "$1" "$2" "$env" "${3:-}")"; }
post_alerts() { curl -fsS -X POST -H 'content-type: application/json' "$AM/api/v2/alerts" -d "[$1]" >/dev/null; }
add_alert DiskSpaceLow critical ',"device":"sda"'
add_alert DiskSpaceLow warning ',"device":"sda"'
add_alert DiskSpaceLow warning ',"device":"sdb"'
add_alert DatabaseUnavailable critical
add_alert HighHTTPErrorRate critical
add_alert InstanceDown critical
add_alert PrometheusTargetMissing warning
add_alert RedisUnavailable warning
add_alert EndpointDown warning ',"service":"shop"'
add_alert EndpointDown warning
post_alerts "$batch"
filter="environment=\"$env\""
am_alerts=$(curl -fsS -G "$AM/api/v2/alerts" --data-urlencode "filter=$filter")
# "<alertname>/<severity>/<device or service>" -> "<state> <receiver>"
state_of() { jq -r --arg k "$1" '.[] | select("\(.labels.alertname)/\(.labels.severity)/\(.labels.device // .labels.service // "")" == $k) | "\(.status.state) \(.receivers[0].name)"' <<<"$am_alerts"; }
check_state() { local got; got=$(state_of "$1"); [ "$got" = "$2" ] && pass "$1 -> $2 ($3)" || bad "$1: got '$got', want '$2' ($3)"; }
check_state DatabaseUnavailable/critical/ "active critical" "critical routes to email + Slack + webhook"
check_state RedisUnavailable/warning/ "active warning" "warning routes to Slack + webhook"
check_state DiskSpaceLow/warning/sda "suppressed warning" "critical twin on the same disk inhibits the warning"
check_state DiskSpaceLow/warning/sdb "active warning" "control: a different disk is not inhibited"
check_state HighHTTPErrorRate/critical/ "suppressed critical" "DatabaseUnavailable explains the 5xx"
check_state PrometheusTargetMissing/warning/ "suppressed warning" "InstanceDown on the same target"
check_state EndpointDown/warning/shop "suppressed warning" "DatabaseUnavailable explains an app's failing health check"
check_state EndpointDown/warning/ "active warning" "control: an endpoint without a service is not inhibited"
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
resolve=$(jq -c --arg t "$now" 'map({labels, endsAt: $t}) | .[]' <<<"$am_alerts" | paste -sd, -)
post_alerts "$resolve"

echo "== End to end: Postgres outage"
# stdout of alert-sink, one JSON object per notification received since $1.
sink_since() { docker compose logs --no-log-prefix --since "$1" alert-sink 2>/dev/null | jq -c 'select(.payload)' 2>/dev/null; }
webhook_has() { # <since> <status>: alert-sink got a webhook for DatabaseUnavailable with that status
  sink_since "$1" | jq -e --arg s "$2" 'select(.path == "/alertmanager" and .payload.status == $s and .payload.receiver == "critical")
    | .payload.alerts[] | select(.labels.alertname == "DatabaseUnavailable" and .labels.environment == "local")' >/dev/null; }
slack_has() { sink_since "$1" | jq -e --arg t "$2" 'select(.path == "/slack" and (.payload.attachments[0].title | startswith($t)))' >/dev/null; }
email_has() { # <since-epoch> <subject prefix>
  curl -fsS "$MAILPIT/api/v1/messages" | jq -e --argjson t "$1" --arg p "$2" '.messages[]
    | select((.Created | sub("\\.[0-9]+"; "") | fromdate) >= $t and (.Subject | startswith($p)))' >/dev/null; }

# Every link in the firing email must open from here (not http://<container-id>:9093).
email_links_open() {
  local id links bad_links= l
  id=$(curl -fsS "$MAILPIT/api/v1/messages" | jq -r '[.messages[] | select(.Subject | startswith("[FIRING:1] DatabaseUnavailable"))][0].ID')
  links=$(curl -fsS "$MAILPIT/api/v1/message/$id" | jq -r .HTML | grep -oE 'href="[^"]+"' | cut -d'"' -f2 | sed 's/&amp;/\&/g; s/&#43;/+/g' | sort -u)
  [ -n "$links" ] || { bad "no links found in the alert email"; return; }
  for l in $links; do curl -fsS -L -o /dev/null -m 5 "$l" 2>/dev/null || bad_links="$bad_links $l"; done
  [ -z "$bad_links" ] && pass "every link in the alert email opens ($(wc -w <<<"$links" | tr -d ' ') links)" || bad "alert email links don't open:$bad_links"
}

receivers=$(docker compose exec -T alertmanager printenv SMTP_SMARTHOST SLACK_WEBHOOK_URL | tr '\n' ' ')
if [ "$receivers" != "mailpit:1025 http://alert-sink:8080/slack " ]; then
  echo "  SKIP  Postgres outage: real email or Slack receivers are configured in .env and would be paged"
  finish
fi

start=$(date -u +%Y-%m-%dT%H:%M:%SZ); start_epoch=$(date +%s)
docker compose stop postgres >/dev/null 2>&1
firing() { [ "$(curl -fsS "$PROM/api/v1/alerts" | jq -r '[.data.alerts[] | select(.labels.alertname == "DatabaseUnavailable" and .state == "firing")] | length')" -gt 0 ]; }
retry 36 5 firing && pass "DatabaseUnavailable firing in Prometheus after $(( $(date +%s) - start_epoch ))s (for: 1m)" || bad "DatabaseUnavailable did not fire within 3 minutes"
retry 18 5 webhook_has "$start" firing && pass "webhook: firing notification (receiver critical, environment=local)" || bad "no firing webhook for DatabaseUnavailable"
slack_has "$start" "[FIRING:1] DatabaseUnavailable" && pass "Slack-format: firing message" || bad "no firing Slack message"
retry 6 5 email_has "$start_epoch" "[FIRING:1] DatabaseUnavailable" && pass "email: firing message in Mailpit" || bad "no firing email in Mailpit"
email_links_open

recovered=$(date -u +%Y-%m-%dT%H:%M:%SZ); recovered_epoch=$(date +%s)
docker compose start postgres >/dev/null 2>&1
retry 30 5 webhook_has "$recovered" resolved && pass "webhook: resolved notification $(( $(date +%s) - recovered_epoch ))s after Postgres restarted" || bad "no resolved webhook"
slack_has "$recovered" "[RESOLVED] DatabaseUnavailable" && pass "Slack-format: resolved message" || bad "no resolved Slack message"
retry 6 5 email_has "$recovered_epoch" "[RESOLVED] DatabaseUnavailable" && pass "email: resolved message in Mailpit" || bad "no resolved email in Mailpit"

failed=$(( $(am_failures) - failures_before ))
[ "$failed" -eq 0 ] && pass "Alertmanager recorded no failed notifications" || bad "$failed notification(s) failed: docker compose logs alertmanager"

health_ok() { [ "$(curl -s "$APP/health" | jq -r .status 2>/dev/null)" = ok ]; }
retry 15 2 health_ok && pass "ecommerce-api healthy again" || bad "ecommerce-api not healthy after Postgres restart"

finish
