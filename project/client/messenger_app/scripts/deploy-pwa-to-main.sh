#!/usr/bin/env bash
# Build PWA for production VPS and upload to main server.
#
# Usage:
#   ./scripts/deploy-pwa-to-main.sh
#   MAIN_HOST=root@194.67.92.147 PWA_PORT=7357 ./scripts/deploy-pwa-to-main.sh
#
# Requires SSH access to main. On first deploy, creates /var/www/messenger-pwa/
# and optionally starts a systemd unit or prints manual serve instructions.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAIN_HOST="${MAIN_HOST:-root@194.67.92.147}"
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
echo "  B) Open firewall port $PWA_PORT on main, then on phone:"
echo "     http://194.67.92.147:$PWA_PORT"
echo
echo "  C) Production: nginx on 443 (see deploy/nginx-pwa.example.conf)"
echo
echo "Baked API URLs in this build:"
echo "  HOME_NODE_URL=http://161.104.18.45:8001"
echo "  MEDIA_NODE_URL=http://161.104.18.45:8004"
echo "  DISCOVERY_NODE_URL=http://194.67.92.147:8003"
echo "  GATEWAY_NODE_URL=http://194.67.92.147:8007"
