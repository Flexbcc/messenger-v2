#!/usr/bin/env bash
# Bootstrap full local stack (docker compose) with sane defaults for all-in-one dev.
#
# Usage: ./scripts/dev-up.sh [--signed]
#   --signed  set INTERNAL_SECURITY_MODE=signed in .env before start
set -euo pipefail

cd "$(dirname "$0")/.."

SIGNED_MODE=false
if [[ "${1:-}" == "--signed" ]]; then
  SIGNED_MODE=true
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker not found. Install Docker and retry." >&2
  exit 1
fi

if [[ ! -f .env ]]; then
  echo "Creating .env from .env.example"
  cp .env.example .env
fi

set_var() {
  local key="$1" value="$2"
  if grep -q "^${key}=" .env 2>/dev/null; then
    tmp=$(mktemp)
    awk -F= -v k="$key" -v v="$value" 'BEGIN{OFS="="} $1==k {print k,v; next} {print}' .env > "$tmp"
    mv "$tmp" .env
  else
    echo "${key}=${value}" >> .env
  fi
}

# Docker-internal service DNS (containers talk to each other).
set_var "DISCOVERY_NODE_URL" "http://discovery-node:8003"
set_var "STORAGE_NODE_URL" "http://storage-node:8002"
set_var "MEDIA_NODE_URL" "http://media-node:8004"

# Public URLs for clients on the host machine.
set_var "HOME_NODE_PUBLIC_URL" "http://localhost:8001"
set_var "MEDIA_NODE_PUBLIC_URL" "http://localhost:8004"
set_var "GATEWAY_NODE_PUBLIC_URL" "http://localhost:8007"
set_var "JWT_SECRET" "dev-local-secret"

if $SIGNED_MODE; then
  set_var "INTERNAL_SECURITY_MODE" "signed"
  set_var "FEDERATION_ENVELOPE_MODE" "signed"
  set_var "PREKEY_CONSUMPTION_MODE" "strict"
else
  set_var "INTERNAL_SECURITY_MODE" "legacy"
  set_var "FEDERATION_ENVELOPE_MODE" "legacy"
  set_var "PREKEY_CONSUMPTION_MODE" "legacy"
fi

echo "Building and starting stack..."
docker compose up -d --build

echo "Waiting for core services..."
for url in \
  "http://localhost:8003/health" \
  "http://localhost:8001/health" \
  "http://localhost:8004/health" \
  "http://localhost:8006/health" \
  "http://localhost:8007/health"
do
  for _ in $(seq 1 30); do
    if curl -sf "$url" >/dev/null 2>&1; then
      echo "  OK $url"
      break
    fi
    sleep 2
  done
done

echo
echo "Stack is up."
echo "  Home:      http://localhost:8001"
echo "  Discovery: http://localhost:8003"
echo "  Media:     http://localhost:8004"
echo "  Gateway:   http://localhost:8007"
echo "  Admin:     http://localhost:\${ADMIN_PORT:-9201}"
echo
echo "Storage and relay are internal-only (no host port)."
echo "Run ./scripts/integration-smoke.sh to verify health endpoints."
