#!/usr/bin/env bash
# Build PWA and upload it to an explicitly selected production host.
#
# Usage:
#   ./scripts/deploy-pwa-to-main.sh
#   MAIN_HOST=root@example.org ./scripts/deploy-pwa-to-main.sh
#
# Requires SSH access to main. On first deploy, creates /var/www/messenger-pwa/
# and optionally starts a systemd unit or prints manual serve instructions.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
: "${MAIN_HOST:?MAIN_HOST=user@host is required}"
REMOTE_DIR="${REMOTE_DIR:-/root/messenger-pwa}"
PWA_PORT="${PWA_PORT:-7357}"

echo "==> Building PWA for production VPS..."
"$ROOT/scripts/build-web-pwa-prod.sh"

OUT="$ROOT/build/web"
if [[ ! -f "$OUT/index.html" ]]; then
  echo "Build failed: $OUT/index.html missing" >&2
  exit 1
fi

echo
echo "==> Preparing remote directory on $MAIN_HOST ..."
ssh "$MAIN_HOST" "mkdir -p '$REMOTE_DIR'"

echo "==> Uploading to $MAIN_HOST:$REMOTE_DIR ..."
rsync -az --delete "$OUT/" "$MAIN_HOST:$REMOTE_DIR/"

echo
echo "==> Deployed. To serve on main (pick one):"
echo
echo "  A) Quick test (foreground, Ctrl+C to stop):"
echo "     ssh $MAIN_HOST 'cd $REMOTE_DIR && python3 -m http.server $PWA_PORT --bind 0.0.0.0'"
echo
echo "  B) Quick HTTP serving is only for a controlled test network."
echo
echo "  C) Production: nginx on 443 (see deploy/nginx-pwa.example.conf)"
echo
echo "Baked API URLs in this build:"
echo "  HOME_NODE_URL=$HOME_NODE_URL"
echo "  MEDIA_NODE_URL=$MEDIA_NODE_URL"
echo "  DISCOVERY_NODE_URL=$DISCOVERY_NODE_URL"
echo "  GATEWAY_NODE_URL=$GATEWAY_NODE_URL"
