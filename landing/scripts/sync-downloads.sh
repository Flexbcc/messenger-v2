#!/usr/bin/env bash
# Copy latest client zips into landing/downloads/ for static hosting.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LANDING="$ROOT/landing"
DIST_ROOT="$ROOT/dist/clients"

STAMP="${1:-$(ls -1 "$DIST_ROOT" 2>/dev/null | sort | tail -1)}"
if [[ -z "$STAMP" || ! -d "$DIST_ROOT/$STAMP" ]]; then
  echo "No build in $DIST_ROOT — run ./scripts/build_clients.sh first" >&2
  exit 1
fi

SRC="$DIST_ROOT/$STAMP"
DEST="$LANDING/downloads"
mkdir -p "$DEST"

for f in Messenger-macos-arm64.zip Messenger-web.zip StorageApp-macos-arm64.zip; do
  if [[ -f "$SRC/$f" ]]; then
    cp -f "$SRC/$f" "$DEST/$f"
    echo "  $f"
  else
    echo "  skip (missing): $f" >&2
  fi
done

# Optional: unpack web for direct browser access at /app/
if [[ -d "$SRC/messenger-web" ]]; then
  rm -rf "$DEST/messenger-web"
  cp -R "$SRC/messenger-web" "$DEST/messenger-web"
  echo "  messenger-web/ (static app)"
fi

echo "Synced build $STAMP → $DEST"

# Release manifest for landing + gateway
if [[ -f "$ROOT/releases/clients/manifest.json" ]]; then
  mkdir -p "$ROOT/landing/releases/clients"
  cp "$ROOT/releases/clients/manifest.json" "$ROOT/landing/releases/clients/manifest.json"
fi
