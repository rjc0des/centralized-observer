#!/usr/bin/env bash
# make reload (also run by make up): validate each config with its own tool, SIGHUP
# the services, then confirm each one actually loaded it. Without the checks, a
# rejected config is silent: the service logs an error and keeps the previous one.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
SERVICES="prometheus alertmanager alloy blackbox"
in_container() { docker compose exec -T "$@"; }

validate() { # validate <service> <command...>
  local svc=$1 out; shift
  out=$("$@" 2>&1) || { echo "$svc: config INVALID, nothing was reloaded:"; echo "$out"; exit 1; }
}
validate prometheus in_container prometheus promtool check config /etc/prometheus/prometheus.yml
validate alertmanager in_container alertmanager /bin/sh /etc/alertmanager/render.sh check
validate alloy in_container alloy alloy validate /etc/alloy/config.alloy
validate blackbox in_container blackbox blackbox_exporter --config.file=/etc/blackbox/blackbox.yml --config.check

# Time of the service's last successful config load, from its own /metrics.
loaded_at() {
  case $1 in
    prometheus) curl -fsS http://127.0.0.1:9090/metrics ;;
    alertmanager) curl -fsS http://127.0.0.1:9093/metrics ;;
    alloy) curl -fsS http://127.0.0.1:12345/metrics ;;
    blackbox) in_container blackbox wget -qO- http://127.0.0.1:9115/metrics ;;
  esac | awk '$1 ~ /_config_last_(re)?load_success_timestamp_seconds$/ {print $2}'
}
before=$(for s in $SERVICES; do echo "$s $(loaded_at "$s")"; done)

docker compose kill -s SIGHUP $SERVICES >/dev/null 2>&1 || { echo "SIGHUP failed: is the stack up?"; exit 1; }

for s in $SERVICES; do
  old=$(awk -v s="$s" '$1 == s {print $2}' <<<"$before")
  for _ in $(seq 1 20); do [ "$(loaded_at "$s")" != "$old" ] && continue 2; sleep 0.5; done
  echo "$s: did not load its config after SIGHUP (make logs S=$s)"; exit 1
done
echo "configs validated and reloaded"
