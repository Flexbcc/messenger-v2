#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FLUTTER="${FLUTTER:-/Users/apple/flutter/bin/flutter}"

DEFINES=(
  "--dart-define=HOME_NODE_URL=${HOME_NODE_URL:-http://localhost:8001}"
  "--dart-define=MEDIA_NODE_URL=${MEDIA_NODE_URL:-http://localhost:8004}"
  "--dart-define=DISCOVERY_NODE_URL=${DISCOVERY_NODE_URL:-http://localhost:8003}"
)

cd "$ROOT"
"$FLUTTER" pub get
"$FLUTTER" build macos --release "${DEFINES[@]}" "$@"

APP="$ROOT/build/macos/Build/Products/Release/messenger_app.app"
echo
echo "Release build ready:"
echo "  $APP"
echo
echo "Open:"
echo "  open \"$APP\""
