#!/usr/bin/env bash
# Build distributable client apps (what this Mac can produce).
# Outputs → dist/clients/<date>/
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FLUTTER="${FLUTTER:-/Users/apple/flutter/bin/flutter}"
export PATH="$(dirname "$FLUTTER"):/opt/homebrew/bin:$PATH"

# Prefer Homebrew OpenJDK for Android Gradle if present
if [[ -z "${JAVA_HOME:-}" && -d /opt/homebrew/opt/openjdk@17 ]]; then
  export JAVA_HOME="/opt/homebrew/opt/openjdk@17"
  export PATH="$JAVA_HOME/bin:$PATH"
fi
if [[ -z "${ANDROID_HOME:-}" && -d "$HOME/Library/Android/sdk" ]]; then
  export ANDROID_HOME="$HOME/Library/Android/sdk"
  export ANDROID_SDK_ROOT="$ANDROID_HOME"
fi

STAMP="${BUILD_STAMP:-$(date -u +%Y%m%d)}"
OUT="${DIST_DIR:-$ROOT/dist/clients/$STAMP}"
mkdir -p "$OUT"

# Production-ish defaults (main/worker from HANDOFF). Override via env.
HOME_URL="${HOME_NODE_URL:-http://161.104.18.45:8001}"
MEDIA_URL="${MEDIA_NODE_URL:-http://161.104.18.45:8004}"
DISC_URL="${DISCOVERY_NODE_URL:-http://194.67.92.147:8003}"
GATE_URL="${GATEWAY_NODE_URL:-http://194.67.92.147:8007}"

DEFINES=(
  "--dart-define=HOME_NODE_URL=$HOME_URL"
  "--dart-define=MEDIA_NODE_URL=$MEDIA_URL"
  "--dart-define=DISCOVERY_NODE_URL=$DISC_URL"
  "--dart-define=GATEWAY_NODE_URL=$GATE_URL"
)

MSG_APP="$ROOT/frontend/app"
STOR_APP="$ROOT/storage-app/app"

log() { echo; echo "==> $*"; }

zip_app() {
  local app_path="$1" zip_name="$2"
  local parent dir
  parent="$(dirname "$app_path")"
  dir="$(basename "$app_path")"
  (cd "$parent" && ditto -c -k --sequesterRsrc --keepParent "$dir" "$OUT/$zip_name")
  echo "    zip: $OUT/$zip_name"
}

# ── Messenger macOS ──────────────────────────────────────────────────────────
if [[ "${SKIP_MESSENGER_MACOS:-0}" != "1" ]]; then
  log "Messenger · macOS release"
  cd "$MSG_APP"
  "$FLUTTER" pub get
  "$FLUTTER" build macos --release "${DEFINES[@]}"
  APP="$MSG_APP/build/macos/Build/Products/Release/messenger_app.app"
  if [[ -d "$APP" ]]; then
    rm -rf "$OUT/Messenger.app"
    cp -R "$APP" "$OUT/Messenger.app"
    zip_app "$OUT/Messenger.app" "Messenger-macos-arm64.zip"
  else
    echo "FAIL: messenger .app not found" >&2
    exit 1
  fi
fi

# ── Messenger Web / PWA ──────────────────────────────────────────────────────
if [[ "${SKIP_MESSENGER_WEB:-0}" != "1" ]]; then
  log "Messenger · web release"
  cd "$MSG_APP"
  "$FLUTTER" build web --release "${DEFINES[@]}"
  rm -rf "$OUT/messenger-web"
  cp -R "$MSG_APP/build/web" "$OUT/messenger-web"
  (cd "$OUT" && ditto -c -k --sequesterRsrc messenger-web "Messenger-web.zip")
  echo "    dir: $OUT/messenger-web"
  echo "    zip: $OUT/Messenger-web.zip"
fi

# ── Storage-app macOS ────────────────────────────────────────────────────────
if [[ "${SKIP_STORAGE_MACOS:-0}" != "1" ]]; then
  log "Storage-app · macOS release"
  cd "$STOR_APP"
  "$FLUTTER" pub get
  "$FLUTTER" build macos --release
  SAPP="$STOR_APP/build/macos/Build/Products/Release/storage_app.app"
  # Flutter may name product from pubspec
  if [[ ! -d "$SAPP" ]]; then
    SAPP="$(find "$STOR_APP/build/macos/Build/Products/Release" -maxdepth 1 -name '*.app' | head -1)"
  fi
  if [[ -d "$SAPP" ]]; then
    rm -rf "$OUT/StorageApp.app"
    cp -R "$SAPP" "$OUT/StorageApp.app"
    zip_app "$OUT/StorageApp.app" "StorageApp-macos-arm64.zip"
  else
    echo "FAIL: storage .app not found" >&2
    exit 1
  fi
fi

# ── Android (optional / best-effort) ─────────────────────────────────────────
if [[ "${SKIP_ANDROID:-0}" != "1" ]]; then
  log "Messenger · Android APK (best-effort)"
  cd "$MSG_APP"
  if "$FLUTTER" build apk --release "${DEFINES[@]}" 2>"$OUT/android-build.log"; then
    APK="$(find "$MSG_APP/build/app/outputs" -name '*.apk' | head -1)"
    cp "$APK" "$OUT/Messenger-android.apk"
    echo "    apk: $OUT/Messenger-android.apk"
  else
    echo "SKIP Android — see $OUT/android-build.log"
    tail -20 "$OUT/android-build.log" || true
  fi
fi

# ── Release manifest + build info ─────────────────────────────────────────────
if [[ -x "$ROOT/scripts/generate-release-manifest.sh" ]]; then
  BUILD_STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$ROOT/scripts/generate-release-manifest.sh"
fi

cat > "$OUT/BUILD_INFO.md" <<EOF
# Client builds — $STAMP

Built on: $(date -u +%Y-%m-%dT%H:%M:%SZ)
Host: $(uname -m) $(sw_vers -productVersion 2>/dev/null || true)
Flutter: $($FLUTTER --version | head -1)

## Dart defines
- HOME_NODE_URL=$HOME_URL
- MEDIA_NODE_URL=$MEDIA_URL
- DISCOVERY_NODE_URL=$DISC_URL
- GATEWAY_NODE_URL=$GATE_URL

## Artifacts
\`\`\`
$(ls -lh "$OUT" | sed '1d')
\`\`\`

## Not built on this Mac
- **Windows** / **Linux** desktop — нужен Windows/Linux host (\`flutter build windows|linux\`)
- **iOS IPA** — нужна Apple Developer signing (\`flutter build ipa\`)
- **Android** — если SKIP выше: поставьте Android cmdline-tools / Studio

## Run macOS apps
\`\`\`
open "$OUT/Messenger.app"
open "$OUT/StorageApp.app"
\`\`\`
EOF

log "Done → $OUT"
cat "$OUT/BUILD_INFO.md"
