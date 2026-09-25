#!/usr/bin/env bash
# Quick smoke test after deploy — no E2EE client required (Phase D / pre-integration).
set -euo pipefail

cd "$(dirname "$0")/.."

fail=0
check() {
  local name="$1" url="$2"
  if curl -sf "$url" >/dev/null; then
    echo "OK  $name"
  else
    echo "FAIL $name ($url)" >&2
    fail=1
  fi
}

check "discovery" "http://localhost:8003/health"
check "home"      "http://localhost:8001/health"
check "media"     "http://localhost:8004/health"
check "turn"      "http://localhost:8006/health"
check "gateway"   "http://localhost:8007/health"

# Storage/relay are internal — probe via docker exec (slim images lack curl)
_internal_health() {
  local service="$1" port="$2"
  if docker compose ps "$service" 2>/dev/null | grep -q Up; then
    if docker compose exec -T "$service" python3 -c \
      "import urllib.request; urllib.request.urlopen('http://localhost:${port}/health').read()" \
      >/dev/null 2>&1; then
      echo "OK  $service (internal)"
    else
      echo "FAIL $service internal health" >&2
      fail=1
    fi
  fi
}

_internal_health storage-node 8002
_internal_health relay-node 8005

if [[ "$fail" -ne 0 ]]; then
  exit 1
fi
echo "Smoke tests passed."
