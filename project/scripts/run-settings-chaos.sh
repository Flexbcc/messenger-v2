#!/usr/bin/env bash
# «Грязный» прогон: 3 пользователя + настройки + переписка.
# Требует: docker compose up (project/) на localhost:8001/8003/8004.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOME_URL="${HOME_URL:-http://localhost:8001}"

if ! curl -sf "$HOME_URL/health" >/dev/null; then
  echo "ERROR: Home Node not reachable at $HOME_URL" >&2
  echo "Start stack: cd $ROOT && docker compose up -d" >&2
  exit 1
fi

DISCOVERY_URL="${DISCOVERY_NODE_URL:-http://[::1]:8003}"

if lsof -iTCP:8003 -sTCP:LISTEN 2>/dev/null | rg -q "127.0.0.1:8003"; then
  echo "NOTE: local process on 127.0.0.1:8003 — using DISCOVERY=$DISCOVERY_URL (Docker via IPv6)." >&2
fi

echo "=== Settings chaos test (HOME=$HOME_URL DISCOVERY=$DISCOVERY_URL) ==="
cd "$ROOT/client/messenger_app"
flutter test test/settings_chaos_integration_test.dart --reporter expanded \
  --dart-define=DISCOVERY_NODE_URL="$DISCOVERY_URL" \
  --dart-define=HOME_NODE_URL="$HOME_URL"
