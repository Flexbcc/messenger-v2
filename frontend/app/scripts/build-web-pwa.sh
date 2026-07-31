#!/usr/bin/env bash
# Production PWA build (static files → build/web/).
#
# URLs are baked in at compile time. For phones on the same Wi‑Fi use your LAN IP:
#   HOME_NODE_URL=http://192.168.1.10:8001 \
#   MEDIA_NODE_URL=http://192.168.1.10:8004 \
#   DISCOVERY_NODE_URL=http://192.168.1.10:8003 \
#   ./scripts/build-web-pwa.sh
#
# For HTTPS deployment behind nginx, use https:// and wss:// (WebSocket follows HOME_NODE_URL).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FLUTTER="${FLUTTER:-/Users/apple/flutter/bin/flutter}"

DEFINES=(
  "--dart-define=HOME_NODE_URL=${HOME_NODE_URL:-http://localhost:8001}"
  "--dart-define=MEDIA_NODE_URL=${MEDIA_NODE_URL:-http://localhost:8004}"
  "--dart-define=DISCOVERY_NODE_URL=${DISCOVERY_NODE_URL:-http://localhost:8003}"
  "--dart-define=GATEWAY_NODE_URL=${GATEWAY_NODE_URL:-http://localhost:8007}"
  "--dart-define=RELAY_NODE_URL=${RELAY_NODE_URL:-http://localhost:8005}"
)

# When PWA is served under a subpath (e.g. :7357/app/), set base href accordingly.
PWA_BASE_HREF="${PWA_BASE_HREF:-/}"

cd "$ROOT"
"$FLUTTER" pub get
"$FLUTTER" build web --release \
  --pwa-strategy=none \
  --base-href="$PWA_BASE_HREF" \
  "${DEFINES[@]}" \
  "$@"

OUT="$ROOT/build/web"
# Serve a precompressed bundle when nginx has gzip_static enabled. Apart from
# reducing CPU work, this gives proxies a fixed Content-Length for the large
# Flutter entrypoint.
gzip -9 -k -f "$OUT/main.dart.js"
echo
echo "PWA build ready:"
echo "  $OUT"
echo
echo "Local preview (same machine):"
echo "  ./scripts/serve-web-pwa.sh"
echo
echo "Baked API URLs:"
echo "  HOME_NODE_URL=${HOME_NODE_URL:-http://localhost:8001}"
echo "  MEDIA_NODE_URL=${MEDIA_NODE_URL:-http://localhost:8004}"
echo "  DISCOVERY_NODE_URL=${DISCOVERY_NODE_URL:-http://localhost:8003}"
