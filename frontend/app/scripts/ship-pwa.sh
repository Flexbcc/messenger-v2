#!/usr/bin/env bash
# One-command: build production PWA + upload + restart on an explicit host.
#
# Setup once:
#   cp deploy/pwa.env.example deploy/pwa.env
#   ssh-copy-id root@pwa.example.org
#   ssh root@pwa.example.org 'bash -s' < deploy/setup-pwa-host.sh
#
# Every deploy from Mac:
#   ./scripts/ship-pwa.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${PWA_ENV:-$ROOT/deploy/pwa.env}"

if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  echo "Loaded $ENV_FILE"
else
  echo "No $ENV_FILE — production host and HTTPS endpoints must be passed explicitly" >&2
fi

: "${MAIN_HOST:?MAIN_HOST=user@host is required}"
export MAIN_HOST
export REMOTE_DIR="${REMOTE_DIR:-/root/messenger-pwa}"
export PORT="${PWA_PORT:-7357}"
export HOME_NODE_URL MEDIA_NODE_URL DISCOVERY_NODE_URL GATEWAY_NODE_URL

echo "==> Build"
"$ROOT/scripts/build-web-pwa-prod.sh"

echo "==> Ship to $MAIN_HOST"
MAIN="$MAIN_HOST" REMOTE_DIR="$REMOTE_DIR" PORT="$PORT" "$ROOT/scripts/remote-start-pwa.sh"

if [[ -n "${PUBLIC_PWA_URL:-}" ]]; then
  echo
  echo "PWA: ${PUBLIC_PWA_URL}"
else
  echo
  echo "Deploy complete. Set PUBLIC_PWA_URL to print the public HTTPS address."
fi
