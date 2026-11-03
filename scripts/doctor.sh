#!/usr/bin/env bash
# Read-only check of the local toolchain. Exit 1 on any FAIL; warnings don't fail.
set -uo pipefail
cd "$(dirname "$0")/.."

fail=0
ok()   { printf '  ok    %s\n' "$*"; }
warn() { printf '  warn  %s\n' "$*"; }
bad()  { printf '  FAIL  %s\n' "$*"; fail=1; }

[ "$(uname -m)" = arm64 ] && ok "host arch arm64" || warn "host arch $(uname -m); images are pinned multi-arch but tested on arm64"

command -v docker >/dev/null || { bad "docker CLI not found"; exit 1; }
docker info >/dev/null 2>&1 || { bad "docker engine not reachable (is OrbStack running?)"; exit 1; }
ok "docker engine $(docker version -f '{{.Server.Version}}')"

ctx=$(docker context show)
[ "$ctx" = orbstack ] && ok "docker context orbstack" || warn "docker context is '$ctx', expected orbstack"

arch=$(docker info -f '{{.Architecture}}')
[ "$arch" = aarch64 ] && ok "engine arch $arch" || warn "engine arch $arch, expected aarch64"

if cv=$(docker compose version --short 2>/dev/null); then ok "docker compose $cv"; else bad "docker compose plugin missing"; fi
docker compose config -q 2>/dev/null && ok "docker-compose.yml valid" || bad "docker-compose.yml invalid (run: docker compose config)"

mem=$(docker info -f '{{.MemTotal}}')
[ "$mem" -ge $((6 * 1024 ** 3)) ] && ok "engine memory $((mem / 1024 ** 3)) GiB" || warn "engine memory $((mem / 1024 ** 3)) GiB, recommend >= 6"

free=$(df -g . | awk 'NR==2 {print $4}')
[ "$free" -ge 20 ] && ok "disk free ${free} GiB" || warn "disk free ${free} GiB, recommend >= 20"

[ -f .env ] && ok ".env present" || warn ".env missing, defaults used (cp .env.example .env)"

# A port is fine if free or already held by this project's own container.
ours=$(docker compose ps --format '{{.Ports}}' 2>/dev/null)
for port in "${FLOCI_PORT:-4566}" 3000 3100 9090 9093 12345; do
  if ! lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then ok "port $port free"
  elif grep -q ":$port->" <<<"$ours"; then ok "port $port in use by this stack"
  else bad "port $port in use by another process"; fi
done

exit $fail
