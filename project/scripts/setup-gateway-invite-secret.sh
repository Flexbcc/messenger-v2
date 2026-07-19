#!/usr/bin/env bash
# Sync GATEWAY_INVITE_SECRET between laptop.env and server .env (gateway-node).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${ROOT}/config/deploy/laptop.env"
EXAMPLE="${ROOT}/config/deploy/laptop.env.example"

if [[ ! -f "$ENV_FILE" ]]; then
  cp "$EXAMPLE" "$ENV_FILE"
fi

SECRET=$(python3 -c "import secrets; print(secrets.token_urlsafe(36))")

if grep -q '^GATEWAY_INVITE_SECRET=' "$ENV_FILE" 2>/dev/null; then
  tmp=$(mktemp)
  awk -F= -v s="$SECRET" 'BEGIN{OFS="="} $1=="GATEWAY_INVITE_SECRET" {print "GATEWAY_INVITE_SECRET",s; next} {print}' "$ENV_FILE" > "$tmp"
  mv "$tmp" "$ENV_FILE"
else
  echo "GATEWAY_INVITE_SECRET=$SECRET" >> "$ENV_FILE"
fi

chmod 600 "$ENV_FILE" 2>/dev/null || true
echo "GATEWAY_INVITE_SECRET → $ENV_FILE"
echo "Добавьте то же значение в .env на main (gateway-node) и перезапустите: docker compose up -d gateway-node"
