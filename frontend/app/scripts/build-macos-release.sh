#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FLUTTER="${FLUTTER:-/Users/apple/flutter/bin/flutter}"

DEFINES=(
  "--dart-define=HOME_NODE_URL=${HOME_NODE_URL:-http://localhost:8001}"
  "--dart-define=MEDIA_NODE_URL=${MEDIA_NODE_URL:-http://localhost:8004}"
  "--dart-define=DISCOVERY_NODE_URL=${DISCOVERY_NODE_URL:-http://localhost:8003}"
  "--dart-define=GATEWAY_NODE_URL=${GATEWAY_NODE_URL:-http://localhost:8007}"
  # This script is for the documented internal localhost build. Distribution
  # builds must override all endpoints with HTTPS and set this to false.
  "--dart-define=ALLOW_INSECURE_BOOTSTRAP_HTTP=${ALLOW_INSECURE_BOOTSTRAP_HTTP:-true}"
)

cd "$ROOT"
"$FLUTTER" pub get
"$FLUTTER" build macos --release "${DEFINES[@]}" "$@"

APP="$ROOT/build/macos/Build/Products/Release/Messenger.app"
if [[ ! -d "$APP" ]]; then
  APP="$(find "$ROOT/build/macos/Build/Products/Release" -maxdepth 1 -name '*.app' -print -quit)"
fi
if [[ ! -d "$APP" ]]; then
  echo "Release app bundle was not produced" >&2
  exit 1
fi
echo
echo "Release build ready:"
echo "  $APP"
echo
echo "Open:"
echo "  open \"$APP\""
