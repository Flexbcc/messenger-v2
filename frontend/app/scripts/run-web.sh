#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FLUTTER="${FLUTTER:-/Users/apple/flutter/bin/flutter}"

DEFINES=(
  "--dart-define=HOME_NODE_URL=${HOME_NODE_URL:-http://localhost:8001}"
  "--dart-define=MEDIA_NODE_URL=${MEDIA_NODE_URL:-http://localhost:8004}"
  "--dart-define=DISCOVERY_NODE_URL=${DISCOVERY_NODE_URL:-http://localhost:8003}"
  "--dart-define=GATEWAY_NODE_URL=${GATEWAY_NODE_URL:-http://localhost:8007}"
  "--dart-define=ALLOW_INSECURE_BOOTSTRAP_HTTP=${ALLOW_INSECURE_BOOTSTRAP_HTTP:-true}"
)

cd "$ROOT"
"$FLUTTER" pub get
"$FLUTTER" run -d chrome --web-port=7357 "${DEFINES[@]}" "$@"
