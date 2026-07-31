#!/usr/bin/env bash
# Production build for current VPS topology (main + worker).
# Main: 194.67.92.147 (discovery, gateway, PWA host)
# Worker: 161.104.18.45 (home, media, turn)
set -euo pipefail

export HOME_NODE_URL="${HOME_NODE_URL:-http://161.104.18.45:8001}"
export MEDIA_NODE_URL="${MEDIA_NODE_URL:-http://161.104.18.45:8004}"
export DISCOVERY_NODE_URL="${DISCOVERY_NODE_URL:-http://194.67.92.147:8003}"
export GATEWAY_NODE_URL="${GATEWAY_NODE_URL:-http://194.67.92.147:8007}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec "$ROOT/scripts/build-web-pwa.sh" "$@"
