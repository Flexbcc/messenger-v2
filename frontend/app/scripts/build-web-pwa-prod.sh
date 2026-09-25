#!/usr/bin/env bash
# Production build. Endpoints are mandatory and must use HTTPS; no historical
# server addresses or insecure fallbacks are embedded in a release build.
set -euo pipefail

: "${HOME_NODE_URL:?HOME_NODE_URL=https://... is required}"
: "${MEDIA_NODE_URL:?MEDIA_NODE_URL=https://... is required}"
: "${DISCOVERY_NODE_URL:?DISCOVERY_NODE_URL=https://... is required}"
: "${GATEWAY_NODE_URL:?GATEWAY_NODE_URL=https://... is required}"
for endpoint in "$HOME_NODE_URL" "$MEDIA_NODE_URL" "$DISCOVERY_NODE_URL" "$GATEWAY_NODE_URL"; do
  case "$endpoint" in
    https://*) ;;
    *) echo "Production endpoint must use HTTPS: $endpoint" >&2; exit 2 ;;
  esac
done
export ALLOW_INSECURE_BOOTSTRAP_HTTP=false

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec "$ROOT/scripts/build-web-pwa.sh" "$@"
