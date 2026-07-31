#!/bin/bash
# build-macos.sh — собирает Flutter macOS desktop app
# Результат: ../project/client/messenger_app/build/macos/Build/Products/Release/messenger_app.app
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLIENT_DIR="$SCRIPT_DIR/../project/client/messenger_app"

# Нода к которой подключается macOS-клиент (по умолчанию — core)
HOME_NODE_URL="${HOME_NODE_URL:-http://localhost:8001}"
MEDIA_NODE_URL="${MEDIA_NODE_URL:-http://localhost:8004}"
DISCOVERY_NODE_URL="${DISCOVERY_NODE_URL:-http://localhost:8103}"

echo "=== msng-test: сборка macOS desktop ==="
echo "  HOME:      $HOME_NODE_URL"
echo "  MEDIA:     $MEDIA_NODE_URL"
echo "  DISCOVERY: $DISCOVERY_NODE_URL"
echo ""

cd "$CLIENT_DIR"

flutter build macos \
  --release \
  --dart-define="HOME_NODE_URL=$HOME_NODE_URL" \
  --dart-define="MEDIA_NODE_URL=$MEDIA_NODE_URL" \
  --dart-define="DISCOVERY_NODE_URL=$DISCOVERY_NODE_URL"

APP_PATH="$CLIENT_DIR/build/macos/Build/Products/Release/messenger_app.app"
echo ""
echo "✓ macOS build готов:"
echo "  $APP_PATH"
echo ""
echo "Запустить: open '$APP_PATH'"
