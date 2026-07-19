#!/usr/bin/env bash
# Serve the built PWA locally (for LAN testing from phones use 0.0.0.0).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/web"
PORT="${PORT:-7357}"
HOST="${HOST:-0.0.0.0}"

if [[ ! -f "$OUT/index.html" ]]; then
  echo "No build found. Run ./scripts/build-web-pwa.sh first." >&2
  exit 1
fi

echo "Serving PWA from $OUT"
echo "  http://127.0.0.1:$PORT"
echo "  http://<LAN-IP>:$PORT  (for phone on same Wi‑Fi)"
echo
echo "Press Ctrl+C to stop."
cd "$OUT"
python3 -m http.server "$PORT" --bind "$HOST"
