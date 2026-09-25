#!/usr/bin/env bash
# Bootstrap full local stack (docker compose) with sane defaults for all-in-one dev.
#
# Usage: ./scripts/dev-up.sh
#
# This command is intentionally a local, insecure-network development profile.
# Production/signed deployments must use scripts/bootstrap-node.py so identity
# and Discovery signing keys are created through the real bootstrap flow.
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ "${1:-}" == "--signed" ]]; then
  echo "--signed is not a dev shortcut. Use: python3 scripts/bootstrap-node.py --dry-run" >&2
  echo "Then run the generated signed deployment plan." >&2
  exit 2
elif [[ $# -gt 0 ]]; then
  echo "Usage: ./scripts/dev-up.sh" >&2
  exit 2
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

generate_secret() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 24
  else
    python3 -c 'import secrets; print(secrets.token_hex(24))'
  fi
}

read_var() {
  awk -F= -v k="$1" '$1==k {sub(/^[^=]*=/, ""); print; exit}' .env
}

ensure_secret() {
  local key="$1" value
  value="$(read_var "$key")"
  if [[ ${#value} -lt 32 || "$value" == *change-me* || "$value" == *replace-with* ]]; then
    set_var "$key" "$(generate_secret)"
    echo "Generated local secret: $key"
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

for key in \
  JWT_SECRET \
  DISCOVERY_ADMIN_SECRET \
  MEDIA_ACCESS_SECRET \
  MEDIA_ADMIN_SECRET \
  MESH_NOTIFY_SECRET \
  GATEWAY_INVITE_SECRET \
  TURN_SHARED_SECRET \
  PUSH_PROXY_SECRET \
  PUSH_TOKEN_ENCRYPTION_SECRET \
  ADMIN_PANEL_SECRET \
  OWNER_PANEL_SECRET
do
  ensure_secret "$key"
done

# Explicit local-lab downgrade. Never copy this profile to production.
set_var "INTERNAL_SECURITY_MODE" "legacy"
set_var "FEDERATION_ENVELOPE_MODE" "legacy"
set_var "PREKEY_CONSUMPTION_MODE" "legacy"
set_var "ALLOW_LEGACY_PREKEY_MODE" "true"
set_var "ALLOW_INSECURE_FEDERATION_MODES" "true"
set_var "ALLOW_INSECURE_DISCOVERY_MODES" "true"
set_var "ALLOW_INSECURE_HOME_MODES" "true"
set_var "ALLOW_INSECURE_STORAGE_MODE" "true"
set_var "ALLOW_INSECURE_PUSH_PROXY" "true"

missing=()
for key in \
  DISCOVERY_NODE_URL JWT_SECRET MEDIA_ACCESS_SECRET MEDIA_ADMIN_SECRET \
  MESH_NOTIFY_SECRET GATEWAY_INVITE_SECRET TURN_SHARED_SECRET \
  PUSH_PROXY_SECRET PUSH_TOKEN_ENCRYPTION_SECRET ADMIN_PANEL_SECRET
do
  [[ -n "$(read_var "$key")" ]] || missing+=("$key")
done
if (( ${#missing[@]} > 0 )); then
  echo "Configuration is incomplete. Missing variables:" >&2
  printf '  - %s\n' "${missing[@]}" >&2
  exit 2
fi

echo "Preflight OK: local development configuration is complete."

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
