#!/usr/bin/env bash
# Deploy landing + PWA (/app/) + downloads + verify on MAIN.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MSG="$ROOT/client/messenger_app"
LANDING="$ROOT/landing"
MAIN="${MAIN_HOST:-root@194.67.92.147}"
REMOTE_DIR="${LANDING_DIR:-/root/messenger-site}"
PORT="${LANDING_PORT:-7357}"
SSH_KEY="${LAPTOP_SSH_KEY:-$HOME/.ssh/messenger_ops}"
SSH=(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new)
RSYNC=(rsync -az -e "ssh -i $SSH_KEY -o StrictHostKeyChecking=accept-new")

log() { echo; echo "==> $*"; }

# ── 1. Release manifest ──────────────────────────────────────────────────────
if [[ -x "$ROOT/scripts/generate-release-manifest.sh" ]]; then
  LANDING_URL="http://194.67.92.147:${PORT}" "$ROOT/scripts/generate-release-manifest.sh"
fi

# ── 2. Build PWA with correct subpath ────────────────────────────────────────
log "Build PWA (base-href=/app/, prod URLs)"
export HOME_NODE_URL="${HOME_NODE_URL:-http://161.104.18.45:8001}"
export MEDIA_NODE_URL="${MEDIA_NODE_URL:-http://161.104.18.45:8004}"
export DISCOVERY_NODE_URL="${DISCOVERY_NODE_URL:-http://194.67.92.147:8003}"
export GATEWAY_NODE_URL="${GATEWAY_NODE_URL:-http://194.67.92.147:8007}"
export PWA_BASE_HREF="/app/"
if [[ -x "$MSG/scripts/build-web-pwa-prod.sh" ]]; then
  "$MSG/scripts/build-web-pwa-prod.sh"
elif [[ -x "$ROOT/../frontend/app/scripts/build-web-pwa-prod.sh" ]]; then
  PWA_BASE_HREF=/app/ "$ROOT/../frontend/app/scripts/build-web-pwa-prod.sh"
else
  echo "PWA build script not found" >&2
  exit 1
fi

WEB_OUT="$MSG/build/web"
[[ -d "$WEB_OUT" ]] || WEB_OUT="$(cd "$ROOT/../frontend/app && pwd)/build/web"
[[ -f "$WEB_OUT/index.html" ]] || { echo "No PWA build at $WEB_OUT" >&2; exit 1; }

# ── 3. Assemble landing bundle locally ───────────────────────────────────────
log "Assemble site bundle"
rm -rf "$LANDING/app"
mkdir -p "$LANDING/app" "$LANDING/downloads" "$LANDING/releases/clients"
cp -R "$WEB_OUT/." "$LANDING/app/"
cp "$ROOT/releases/clients/manifest.json" "$LANDING/releases/clients/manifest.json"

# Optional desktop zips (if built locally)
DIST="$ROOT/../dist/clients"
STAMP="$(ls -1 "$DIST" 2>/dev/null | sort | tail -1 || true)"
if [[ -n "$STAMP" && -d "$DIST/$STAMP" ]]; then
  for f in Messenger-macos-arm64.zip Messenger-web.zip StorageApp-macos-arm64.zip; do
    [[ -f "$DIST/$STAMP/$f" ]] && cp -f "$DIST/$STAMP/$f" "$LANDING/downloads/"
  done
  (cd "$LANDING/downloads" && ditto -c -k --sequesterRsrc app "Messenger-web.zip" 2>/dev/null || true)
fi

# ── 4. Upload ─────────────────────────────────────────────────────────────────
log "Upload → $MAIN:$REMOTE_DIR"
"${SSH[@]}" "$MAIN" "mkdir -p '$REMOTE_DIR'"
"${RSYNC[@]}" --delete "$LANDING/" "$MAIN:$REMOTE_DIR/"

# ── 5. Restart static server ───────────────────────────────────────────────────
log "Restart http.server :$PORT"
"${SSH[@]}" "$MAIN" bash -s <<EOF
set -e
pkill -f "http.server $PORT" 2>/dev/null || true
cd '$REMOTE_DIR'
nohup python3 -m http.server $PORT --bind 0.0.0.0 > /tmp/messenger-site.log 2>&1 &
sleep 1
EOF

# ── 6. Verify ─────────────────────────────────────────────────────────────────
log "Verify endpoints"
"${SSH[@]}" "$MAIN" bash -s <<'VERIFY'
set -e
check() {
  local url="$1" expect="$2"
  code=$(curl -s -o /dev/null -w '%{http_code}' "$url")
  if [[ "$code" != "$expect" ]]; then
    echo "FAIL $code (want $expect) $url" >&2
    exit 1
  fi
  echo "OK $code $url"
}
check http://127.0.0.1:7357/ 200
check http://127.0.0.1:7357/releases/clients/manifest.json 200
check http://127.0.0.1:7357/app/index.html 200
check http://127.0.0.1:7357/app/manifest.json 200
check http://127.0.0.1:7357/app/flutter_bootstrap.js 200
check http://127.0.0.1:8007/releases/clients/manifest.json 200
check http://127.0.0.1:8007/health 200
grep -q 'base href="/app/"' /root/messenger-site/app/index.html && echo OK base-href
VERIFY

echo
echo "Site:  http://194.67.92.147:${PORT}/"
echo "PWA:   http://194.67.92.147:${PORT}/app/"
echo "Manifest (updates): http://194.67.92.147:8007/releases/clients/manifest.json"
