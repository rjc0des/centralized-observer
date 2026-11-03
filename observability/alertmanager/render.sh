#!/bin/sh
# Entrypoint: render alertmanager.yml's ${VAR} placeholders from the environment, then
# run Alertmanager on the result. Fails (and Alertmanager doesn't start) if a
# placeholder has no variable, rather than silently rendering an empty value, or if a
# value holds a character that would break out of its YAML string.
set -eu
awk '{
  out = ""
  while (match($0, /\$\{[A-Z0-9_]+\}/)) {
    name = substr($0, RSTART + 2, RLENGTH - 3)
    if (!(name in ENVIRON)) { print "render.sh: " name " is not set" > "/dev/stderr"; exit 1 }
    if (ENVIRON[name] ~ /["\\]/) { print "render.sh: " name " must not contain \" or \\" > "/dev/stderr"; exit 1 }
    out = out substr($0, 1, RSTART - 1) ENVIRON[name]
    $0 = substr($0, RSTART + RLENGTH)
  }
  print out $0
}' /etc/alertmanager/alertmanager.yml > /tmp/alertmanager.yml
# `render.sh check` validates instead of starting (make unit; make reload, which then
# SIGHUPs Alertmanager to load the freshly rendered file).
[ "${1:-}" = check ] && exec amtool check-config /tmp/alertmanager.yml
exec alertmanager --config.file=/tmp/alertmanager.yml "$@"
