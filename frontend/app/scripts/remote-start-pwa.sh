#!/usr/bin/env bash
# Upload PWA and start HTTP server ON MAIN (194.67.92.147), not on your Mac.
#
# Run from messenger_app/ on Mac (will ask SSH password twice: rsync + ssh):
#   ./scripts/remote-start-pwa.sh
#
# Stop remote server:
#   ssh root@194.67.92.147 'pkill -f "http.server 7357" || true'
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAIN="${MAIN:-root@194.67.92.147}"
REMOTE_DIR="${REMOTE_DIR:-/root/messenger-pwa}"
PORT="${PORT:-7357}"
OUT="$ROOT/build/web"

if [[ ! -f "$OUT/index.html" ]]; then
  echo "No build at $OUT — run ./scripts/build-web-pwa-prod.sh first" >&2
  exit 1
fi

echo "==> 1/2 Upload build/web → $MAIN:$REMOTE_DIR"
ssh "$MAIN" "mkdir -p '$REMOTE_DIR'"
rsync -az --delete "$OUT/" "$MAIN:$REMOTE_DIR/"

echo
echo "==> 2/2 Start / restart PWA on server"
ssh "$MAIN" bash -s <<EOF
set -e
mkdir -p '$REMOTE_DIR'
if systemctl list-unit-files | grep -q messenger-pwa; then
  systemctl restart messenger-pwa
  sleep 1
  curl -sf -o /dev/null "http://127.0.0.1:$PORT/" && echo "OK: systemd messenger-pwa on port $PORT"
else
  pkill -f "http.server $PORT" 2>/dev/null || true
  cd '$REMOTE_DIR'
  nohup python3 -m http.server $PORT --bind 0.0.0.0 > /tmp/messenger-pwa.log 2>&1 &
  sleep 1
  curl -sf -o /dev/null "http://127.0.0.1:$PORT/" && echo "OK: python http.server on port $PORT"
fi
EOF

echo
echo "Done. Do NOT run python3 -m http.server on Mac for phone testing."
echo "If phone cannot connect, open port $PORT in firewall on main."
