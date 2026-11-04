#!/usr/bin/env bash
# Integration test for the incident API on the running stack: auth, validation,
# deduplication, correlation, lifecycle, reports, concurrency, database roles, metrics,
# and an incident-db outage (webhooks are spooled and recorded once it is back).
# Alerts are posted straight to the webhook in a throwaway environment
# (incident-test-<pid>); every incident it opens is resolved at the end. Incidents are
# never deleted (the app role can't), so resolved test incidents stay in the history.
# Needs `make up` first. Briefly stops incident-db. Exit 1 on failure.
set -uo pipefail
source "$(dirname "$0")/lib.sh"

IAPI=http://127.0.0.1:8081
ENV_T="incident-test-$$"
T0=$(date -u +%Y-%m-%dT%H:%M:%SZ)
start_epoch=$(date +%s)
AUTH="Authorization: Bearer $INCIDENT_API_TOKEN"

cleanup() {
  docker compose start incident-db >/dev/null 2>&1
  retry 20 1 curl -fs -o /dev/null "$IAPI/health"
  for id in $(curl -s "$IAPI/incidents?environment=$ENV_T&limit=500" | jq -r '.[] | select(.status != "resolved") | .id' 2>/dev/null); do
    post "/incidents/$id/resolve" '{"actor":"incidents.sh","note":"test cleanup"}' >/dev/null
  done
}
trap cleanup EXIT

# post <path> <json> [token]: prints the HTTP status code.
post() { curl -s -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer ${3:-$INCIDENT_API_TOKEN}" \
  -H 'content-type: application/json' "$IAPI$1" -d "$2"; }
post_body() { curl -s -X POST -H "$AUTH" -H 'content-type: application/json' "$IAPI$1" -d "$2"; }
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
# alert <status> <alertname> <severity> <fingerprint> [extra labels JSON] [startsAt]
alert() {
  local extra=${5:-}; [ -n "$extra" ] || extra='{}'
  jq -nc --arg st "$1" --arg n "$2" --arg sev "$3" --arg fp "$4-$$" --argjson x "$extra" --arg env "$ENV_T" \
    --arg starts "${6:-$T0}" --arg now "$(now)" \
    '{status: $st, labels: ({alertname: $n, severity: $sev, environment: $env} + $x),
      annotations: {summary: "\($n) (test)"}, startsAt: $starts,
      endsAt: (if $st == "resolved" then $now else "0001-01-01T00:00:00Z" end), fingerprint: $fp}'
}
payload() { printf '{"version":"4","status":"firing","receiver":"test","alerts":[%s]}' "$1"; }
notify() { post /alertmanager "$(payload "$1")"; }
notify_body() { post_body /alertmanager "$(payload "$1")"; }
incidents() { curl -s "$IAPI/incidents?environment=$ENV_T&limit=500"; }
# incident_with <alertname>: id of the newest incident in the test environment containing it.
incident_with() { incidents | jq -r --arg n "$1" '[.[] | select(.alertnames | index($n))][0].id // empty'; }
incident() { curl -s "$IAPI/incidents/$1"; }
check() { # check <description> <jq filter that must be true> <json>
  jq -e "$2" <<<"$3" >/dev/null 2>&1 && pass "$1" || bad "$1 (got: $(head -c 300 <<<"$3"))"; }

echo "== Auth and validation"
a=$(alert firing DiskSpaceLow warning disk-sda '{"device":"sda"}')
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'content-type: application/json' "$IAPI/alertmanager" -d "$(payload "$a")")
[ "$code" = 401 ] && pass "webhook without token -> 401" || bad "webhook without token -> $code"
code=$(post /alertmanager "$(payload "$a")" wrong-token)
[ "$code" = 401 ] && pass "webhook with a wrong token -> 401" || bad "webhook with a wrong token -> $code"
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'content-type: application/json' "$IAPI/alertmanager" -d '{bad')
[ "$code" = 401 ] && pass "unparseable body without token -> 401 (token checked before the body is read)" || bad "bad body without token -> $code"
nameless=$(jq -c '.labels |= del(.alertname) | .fingerprint = "nameless"' <<<"$a")
check "alert without alertname is skipped, not a 4xx (Alertmanager never retries those)" '.skipped == 1 and .new == 0' \
  "$(notify_body "$nameless")"
code=$(post /alertmanager "$(jq -c '{alerts: [.startsAt = "2026-01-01T00:00:00"]}' <<<"$a")")
[ "$code" = 422 ] && pass "startsAt without a timezone -> 422" || bad "startsAt without a timezone -> $code"
[ "$(incidents | jq length)" = 0 ] && pass "rejected webhooks created nothing" || bad "rejected webhooks created incidents"

echo "== Deduplication"
check "first notification: alert is new; a nameless one beside it is skipped" '.new == 1 and .skipped == 1' "$(notify_body "$a,$nameless")"
check "re-sent notification: duplicate" '.duplicate == 1 and .new == 0' "$(notify_body "$a")"
disk=$(incident_with DiskSpaceLow)
check "one incident, one alert, one firing event after the re-send" \
  '(.alerts | length) == 1 and ([.events[] | select(.kind == "alert_firing")] | length) == 1 and .status == "open"' "$(incident "$disk")"

echo "== Correlation"
notify "$(alert firing DiskSpaceLow warning disk-sdb '{"device":"sdb"}')" >/dev/null
notify "$(alert firing DiskSpaceLow critical disk-sda-crit '{"device":"sda"}')" >/dev/null
d=$(incident "$disk")
check "same alert on another disk joins the incident (rule same-alert)" \
  '(.alerts | length) == 3 and ([.events[].detail | select(test("same-alert"))] | length) == 2' "$d"
check "a critical alert raises the incident to critical" \
  '.severity == "critical" and ([.events[] | select(.kind == "severity_raised")] | length) == 1' "$d"

notify "$(alert firing DatabaseUnavailable critical db)" >/dev/null
db=$(incident_with DatabaseUnavailable)
[ -n "$db" ] && [ "$db" != "$disk" ] && pass "unrelated alert opens its own incident" || bad "DatabaseUnavailable incident: '$db' (disk incident $disk)"
notify "$(alert firing HighHTTPErrorRate critical errors-shop '{"service":"ecommerce-api"}')" >/dev/null
check "ecommerce-api 5xx joins the database incident (rule database-down)" \
  '([.alerts[].alertname] | sort) == ["DatabaseUnavailable","HighHTTPErrorRate"] and ([.events[].detail | select(test("database-down"))] | length) == 1' \
  "$(incident "$db")"
notify "$(alert firing EndpointDown warning health-incident '{"service":"incident-api","instance":"http://incident-api:8000/health"}')" >/dev/null
other=$(incident_with EndpointDown)
[ -n "$other" ] && [ "$other" != "$db" ] && pass "control: another service's failing health check is not blamed on Postgres" \
  || bad "EndpointDown{service=incident-api} landed in incident '$other' (database incident $db)"
notify "$(alert firing HighHTTPErrorRate critical errors-incident '{"service":"incident-api"}')" >/dev/null
[ "$(incident_with HighHTTPErrorRate)" = "$other" ] && pass "same service's alerts share an incident (rule same-service)" \
  || bad "HighHTTPErrorRate{service=incident-api} not in incident $other"

echo "== Concurrency"
# 20 related alerts in 20 simultaneous webhooks must still form one incident. Each
# request takes milliseconds, too short to overlap reliably (without the webhook lock
# this still passed), so a session holds inserts into `incidents` for a few seconds:
# all 20 are then in flight at once, and without the lock each would see "no incident
# yet" and open its own (verified: 20 incidents).
race_alert() { alert firing ConcurrencyProbe warning "race-$1" "$(printf '{"instance":"i%s"}' "$1")"; }
race_dir=$(mktemp -d)
args=(-Z --parallel-immediate --parallel-max 20)
for i in $(seq 1 20); do
  payload "$(race_alert "$i")" > "$race_dir/$i.json"
  args+=(-s -o /dev/null -H "$AUTH" -H 'content-type: application/json' -d "@$race_dir/$i.json" "$IAPI/alertmanager" --next)
done
docker compose exec -T -e PGPASSWORD="$INCIDENT_OWNER_PASSWORD" incident-db psql -h 127.0.0.1 -U incident_owner \
  -d incidents -q -c 'BEGIN' -c 'LOCK TABLE incidents IN SHARE MODE' -c 'SELECT pg_sleep(3)' -c 'COMMIT' >/dev/null &
holder=$!
sleep 1
curl "${args[@]}" -s -o /dev/null "$IAPI/health"
wait $holder
rm -rf "$race_dir"
race=$(incidents | jq '[.[] | select(.alertnames == ["ConcurrencyProbe"])] | length')
alerts_in=$(incident "$(incident_with ConcurrencyProbe)" | jq '.alerts | length')
[ "$race" = 1 ] && [ "$alerts_in" = 20 ] && pass "20 concurrent webhooks -> 1 incident with 20 alerts" \
  || bad "20 concurrent webhooks -> $race incident(s), $alerts_in alerts in the newest"

echo "== Lifecycle"
code=$(post "/incidents/$db/acknowledge" '{"actor":"ana"}')
[ "$code" = 200 ] && pass "acknowledge -> 200" || bad "acknowledge -> $code"
code=$(post "/incidents/$db/acknowledge" '{"actor":"ana"}')
[ "$code" = 409 ] && pass "acknowledge twice -> 409" || bad "acknowledge twice -> $code"
code=$(post "/incidents/$db/acknowledge" '{"actor":""}')
[ "$code" = 422 ] && pass "empty actor -> 422" || bad "empty actor -> $code"
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'content-type: application/json' "$IAPI/incidents/$db/resolve" -d '{"actor":"x"}')
[ "$code" = 401 ] && pass "resolve without token -> 401" || bad "resolve without token -> $code"
code=$(post "/incidents/$db/notes" '{"actor":"ana","text":"failover started | see runbook"}')
[ "$code" = 201 ] && pass "add a note -> 201" || bad "add a note -> $code"
code=$(post /incidents/999999999/acknowledge '{"actor":"ana"}')
[ "$code" = 404 ] && pass "unknown incident -> 404" || bad "unknown incident -> $code"

notify "$(alert resolved DatabaseUnavailable critical db),$(alert resolved HighHTTPErrorRate critical errors-shop '{"service":"ecommerce-api"}')" >/dev/null
d=$(incident "$db")
check "all alerts resolved -> incident auto-resolves" \
  '.status == "resolved" and .resolved_at != null and .acknowledged_at != null and ([.events[] | select(.kind == "resolved" and .actor == "alertmanager")] | length) == 1' "$d"
notify "$(alert firing DatabaseUnavailable critical db)" >/dev/null
[ "$(incident "$db" | jq -r .status)" = resolved ] && [ "$(incident_with DatabaseUnavailable)" = "$db" ] \
  && pass "late re-send of an already resolved alert changes nothing" || bad "late firing re-send reopened or created an incident"
later=$(jq -rn --arg t "$T0" '$t | fromdate + 60 | todate')   # a new firing has a new startsAt
notify "$(alert firing DatabaseUnavailable critical db '' "$later")" >/dev/null
again=$(incident_with DatabaseUnavailable)
[ -n "$again" ] && [ "$again" != "$db" ] && pass "the same alert firing again later opens a new incident" || bad "new firing went to incident '$again'"

code=$(post "/incidents/$disk/resolve" '{"actor":"ana","note":"disk grown"}')
[ "$code" = 200 ] && pass "manual resolve while alerts still fire -> 200" || bad "manual resolve -> $code"
code=$(post "/incidents/$disk/acknowledge" '{"actor":"ana"}')
[ "$code" = 409 ] && pass "acknowledge a resolved incident -> 409" || bad "acknowledge a resolved incident -> $code"
code=$(post "/incidents/$disk/resolve" '{"actor":"ana"}')
[ "$code" = 409 ] && pass "resolve a resolved incident -> 409" || bad "resolve a resolved incident -> $code"

notify "$(alert resolved RedisUnavailable warning redis)" >/dev/null
check "resolved-only alert (firing never received) -> incident recorded, already resolved" \
  '.status == "resolved" and ([.events[].kind] | index("alert_firing") != null and index("alert_resolved") != null)' \
  "$(incident "$(incident_with RedisUnavailable)")"

echo "== Restarts, ordering and races"
# After Prometheus + Alertmanager restart, a still-firing alert comes back with a new
# startsAt; its resolved notification carries that one.
notify "$(alert firing RestartProbe warning restart)" >/dev/null
restarted=$(jq -rn --arg t "$T0" '$t | fromdate + 120 | todate')
notify "$(alert resolved RestartProbe warning restart '' "$restarted")" >/dev/null
check "resolved with a restart's new startsAt closes the original firing (no second row)" \
  '.status == "resolved" and (.alerts | length) == 1 and .alerts[0].status == "resolved"' "$(incident "$(incident_with RestartProbe)")"
# Out of order: the alert that ended later is reported first.
early_start=$(jq -rn --arg t "$T0" '$t | fromdate - 1200 | todate'); early_end=$(jq -rn --arg t "$T0" '$t | fromdate - 600 | todate')
notify "$(alert firing OrderProbe warning order-a '' "$early_start"),$(alert firing OrderProbe warning order-b '' "$early_start")" >/dev/null
notify "$(alert resolved OrderProbe warning order-b '' "$early_start")" >/dev/null
notify "$(alert resolved OrderProbe warning order-a '' "$early_start" | jq -c --arg e "$early_end" '.endsAt = $e')" >/dev/null
check "out-of-order resolutions: incident ends at the latest alert end, 'resolved' is the last event" \
  '.status == "resolved" and .resolved_at == ([.alerts[].ends_at] | max) and .events[-1].kind == "resolved"' \
  "$(incident "$(incident_with OrderProbe)")"
# A resolve racing a webhook: a session holds inserts into `alerts`, so the webhook has
# picked the open incident but not yet added its alert when the resolve arrives. Without a
# shared lock the resolve committed first and the alert landed in a resolved incident.
notify "$(alert firing ResolveRace warning rr-1)" >/dev/null
rr=$(incident_with ResolveRace)
docker compose exec -T -e PGPASSWORD="$INCIDENT_OWNER_PASSWORD" incident-db psql -h 127.0.0.1 -U incident_owner \
  -d incidents -q -c 'BEGIN' -c 'LOCK TABLE alerts IN SHARE MODE' -c 'SELECT pg_sleep(4)' -c 'COMMIT' >/dev/null &
sleep 1
rr2=$(payload "$(alert firing ResolveRace warning rr-2)")
post /alertmanager "$rr2" >/dev/null &
sleep 1
post "/incidents/$rr/resolve" '{"actor":"ana"}' >/dev/null
wait
order=$(docker compose exec -T -e PGPASSWORD="$INCIDENT_OWNER_PASSWORD" incident-db psql -h 127.0.0.1 -U incident_owner \
  -d incidents -tAq -c "SELECT string_agg(kind, ' ' ORDER BY id) FROM events WHERE incident_id = $rr")
[ "$order" = "alert_firing alert_firing resolved" ] && pass "resolve racing a webhook: the alert joins before the resolve, never after" \
  || bad "event order in incident $rr: $order"

echo "== Reports"
ctype=$(curl -s -o /dev/null -w '%{content_type}' "$IAPI/incidents/$db/report")
report=$(curl -s "$IAPI/incidents/$db/report")
case $ctype in text/markdown*) pass "report served as text/markdown" ;; *) bad "report content type: $ctype" ;; esac
grep -q "| Probable cause | DatabaseUnavailable: DatabaseUnavailable (test) |" <<<"$report" \
  && grep -q 'correlated by rule database-down' <<<"$report" && grep -q 'failover started \\| see runbook' <<<"$report" \
  && pass "report names the probable cause, the correlation rule and the escaped note" || bad "report content: $(head -c 400 <<<"$report")"
check "summary counts this run's incidents" '.incidents >= 6 and .by_severity.critical >= 2 and .mean_time_to_acknowledge_seconds != null' \
  "$(curl -s "$IAPI/reports/summary?environment=$ENV_T")"

echo "== Database roles"
# Statements run inside BEGIN/ROLLBACK, so even a wrongly granted DELETE would be undone.
psql_app() { docker compose exec -T -e PGPASSWORD="$INCIDENT_APP_PASSWORD" incident-db \
  psql -h 127.0.0.1 -U incident_app -d incidents -tAq -v ON_ERROR_STOP=1 -c 'BEGIN' -c "$1" -c 'ROLLBACK' 2>&1; }
for stmt in 'DELETE FROM incidents' 'UPDATE events SET detail = NULL' 'DELETE FROM events' 'CREATE TABLE t ()' 'DROP TABLE alerts'; do
  out=$(psql_app "$stmt")
  grep -q 'permission denied\|must be owner' <<<"$out" && pass "incident_app cannot: $stmt" || bad "incident_app ran '$stmt': $out"
done

echo "== Reconciliation with Alertmanager"
# Alertmanager keeps alerts in memory only: a restart can lose an alert's resolved
# notification. Alerts missing from Alertmanager for 10 minutes are resolved; the test
# backdates "missing since" instead of waiting. Control: an alert Alertmanager has (posted
# to its API, withdrawn before group_wait so nothing is notified) is kept.
AM=http://127.0.0.1:9093
psql_owner() { docker compose exec -T -e PGPASSWORD="$INCIDENT_OWNER_PASSWORD" incident-db \
  psql -h 127.0.0.1 -U incident_owner -d incidents -tAq -v ON_ERROR_STOP=1 -c "$1" 2>&1; }
am_alert() { jq -nc --arg env "$ENV_T" --arg t "$T0" --arg end "${1:-}" \
  '[{labels: {alertname: "ReconcileKeep", severity: "warning", environment: $env}, startsAt: $t}
    | if $end != "" then .endsAt = $end else . end]'; }
curl -fsS -X POST -H 'content-type: application/json' "$AM/api/v2/alerts" -d "$(am_alert)"
am_filter="environment=\"$ENV_T\""
fp=$(curl -fsS -G "$AM/api/v2/alerts" --data-urlencode "filter=$am_filter" | jq -r '.[0].fingerprint')
keep=$(alert firing ReconcileKeep warning x | jq -c --arg fp "$fp" '.fingerprint = $fp')
notify "$keep" >/dev/null
notify "$(alert firing ReconcileLost warning lost)" >/dev/null
backdated=$(psql_owner "UPDATE alerts SET missing_since = now() - interval '11 minutes'
  WHERE labels->>'environment' = '$ENV_T' AND alertname IN ('ReconcileKeep', 'ReconcileLost') RETURNING id" | grep -c .)
[ "$backdated" = 2 ] || bad "backdated $backdated alerts, want 2"
lost_resolved() { [ "$(incident "$(incident_with ReconcileLost)" | jq -r .status)" = resolved ]; }
retry 8 5 lost_resolved && pass "alert gone from Alertmanager for 10 minutes -> resolved, incident closed" \
  || bad "ReconcileLost still open after 40s (reconciliation runs every 15s)"
check "timeline says why it was resolved" '[.events[].detail | select(test("gone from Alertmanager"))] | length == 1' \
  "$(incident "$(incident_with ReconcileLost)")"
check "control: an alert Alertmanager still has stays firing" '.status == "open" and .alerts[0].status == "firing"' \
  "$(incident "$(incident_with ReconcileKeep)")"
curl -fsS -X POST -H 'content-type: application/json' "$AM/api/v2/alerts" -d "$(am_alert "$(now)")"

echo "== incident-db outage"
# Webhooks are spooled, so an alert that fires and clears during the outage is kept
# (with 503s, Alertmanager never sent its resolved notification: reproduced).
docker compose stop incident-db >/dev/null 2>&1
check "webhook during the outage -> accepted into the spool" '.spooled == 1' "$(notify_body "$(alert firing OutageProbe warning outage)")"
check "its resolution during the outage -> spooled too" '.spooled == 1' "$(notify_body "$(alert resolved OutageProbe warning outage)")"
code=$(curl -s -o /dev/null -w '%{http_code}' "$IAPI/health")
[ "$code" = 503 ] && pass "/health -> 503 while incident-db is down" || bad "/health during outage -> $code"
m=$(curl -s "$IAPI/metrics")
grep -q '^incident_spool_pending 2' <<<"$m" && ! grep -q '^incidents_open' <<<"$m" \
  && pass "/metrics: 2 webhooks pending in the spool, incidents_open left out (unknown)" \
  || bad "/metrics during outage: $(grep -E '^(incident_spool_pending|incidents_open)' <<<"$m" | tr '\n' ' ')"
panel=$(jq -r '.panels[] | select(.title == "Open incidents") | .targets[0].expr' observability/grafana/provisioning/dashboards/overview.json)
panel_empty() { [ "$(prom_count "$panel")" = 0 ]; }
retry 12 5 panel_empty && pass "Overview 'Open incidents' shows unknown, not 0, during the outage" || bad "panel query still returns a value: $panel"
# Matched on this run's environment, not `--since`: a time-filtered check failed once
# (1 of 6 runs) with the line present by every other measure; not reproduced.
docker compose logs incident-api 2>&1 | grep 'webhook spooled' | grep -q "\"$ENV_T\"" \
  && pass "spooling logged as a warning, naming the environment" || bad "no 'webhook spooled' log line for $ENV_T"
docker compose start incident-db >/dev/null 2>&1
retry 30 1 curl -fs -o /dev/null "$IAPI/health" && pass "/health ok after incident-db restarts" || bad "/health not ok after restart"
outage_recorded() { [ "$(incident "$(incident_with OutageProbe)" | jq -r .status 2>/dev/null)" = resolved ]; }
retry 10 3 outage_recorded && pass "spool replayed without any re-send: the outage's alert recorded, fired and resolved" \
  || bad "OutageProbe not recorded after incident-db came back"
[ "$(curl -s "$IAPI/metrics" | awk '/^incident_spool_pending/ {print $2}')" = 0.0 ] && pass "spool empty again" || bad "spool not drained"

echo "== Metrics and logs"
m=$(curl -s "$IAPI/metrics")
grep -q "^incidents_open{environment=\"$ENV_T\",severity=" <<<"$m" && pass "incidents_open reports this run's open incidents" || bad "incidents_open missing for $ENV_T"
grep -q 'route="/incidents/{incident_id}/acknowledge"' <<<"$m" && ! grep -q 'route="/incidents/[0-9]' <<<"$m" \
  && pass "http metrics use route templates, never ids" || bad "route label: $(grep -o 'route="[^"]*"' <<<"$m" | sort -u | tr '\n' ' ')"
grep -q 'route="/health"\|route="/metrics"' <<<"$m" && bad "probe/scrape traffic counted in http_requests_total (it would become the SLO)" \
  || pass "probes and scrapes are not counted as requests (the outage's /health 503s burn no error budget)"
retry 12 5 prom_is 'up{job="apps",service="incident-api"}' 1 && pass "Prometheus scrapes incident-api" || bad "incident-api not scraped (up != 1)"
retry 12 5 prom_is 'probe_success{service="incident-api"}' 1 && pass "Blackbox health probe of incident-api succeeds" || bad "incident-api probe failing"
retry 12 5 loki_has '{service="incident-api"} | json | msg="webhook processed"' "$start_epoch" \
  && pass "incident-api JSON logs reach Loki" || bad "no incident-api webhook logs in Loki"

cleanup
[ "$(incidents | jq '[.[] | select(.status != "resolved")] | length')" = 0 ] \
  && pass "cleanup: every test incident resolved" || bad "test incidents left open in $ENV_T"
finish
