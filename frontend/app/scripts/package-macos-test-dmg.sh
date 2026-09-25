#!/usr/bin/env bash
set -euo pipefail

APP_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(cd "$APP_ROOT/../.." && pwd)"
APP="$APP_ROOT/build/macos/Build/Products/Release/Messenger.app"
VERSION="${OUO_CLIENT_VERSION:-0.1.0}"
OUTPUT_DIR="${OUO_DMG_OUTPUT_DIR:-$REPO_ROOT/dist/clients/$(date -u +%Y%m%d)}"
OUTPUT="$OUTPUT_DIR/Messenger-${VERSION}-macos-arm64-test.dmg"

if [[ ! -d "$APP" ]]; then
  echo "Messenger.app is missing; run scripts/build-macos-release.sh first" >&2
  exit 1
fi
if [[ -e "$OUTPUT" ]]; then
  echo "Refusing to overwrite existing image: $OUTPUT" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"
hdiutil create \
  -volname "OUO Messenger Test" \
  -srcfolder "$APP" \
  -format UDZO \
  "$OUTPUT"
hdiutil verify "$OUTPUT"
shasum -a 256 "$OUTPUT"
echo "Test DMG ready: $OUTPUT"
