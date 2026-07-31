#!/bin/bash
# build-web.sh — собирает Flutter web и кладёт в msng-test/web-build/
# Запускать из корня msng-test/
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/../project"
CLIENT_DIR="$PROJECT_DIR/client/messenger_app"
OUT_DIR="$SCRIPT_DIR/web-build"

# Конфигурация нод — по умолчанию core (можно переопределить через env)
HOME_NODE_URL="${HOME_NODE_URL:-http://localhost:8001}"
MEDIA_NODE_URL="${MEDIA_NODE_URL:-http://localhost:8004}"
DISCOVERY_NODE_URL="${DISCOVERY_NODE_URL:-http://localhost:8103}"
GATEWAY_NODE_URL="${GATEWAY_NODE_URL:-http://localhost:8007}"

echo "=== msng-test: сборка Flutter web ==="
echo "  HOME:      $HOME_NODE_URL"
echo "  MEDIA:     $MEDIA_NODE_URL"
echo "  DISCOVERY: $DISCOVERY_NODE_URL"
echo ""

cd "$CLIENT_DIR"

flutter build web \
  --release \
  --dart-define="HOME_NODE_URL=$HOME_NODE_URL" \
  --dart-define="MEDIA_NODE_URL=$MEDIA_NODE_URL" \
  --dart-define="DISCOVERY_NODE_URL=$DISCOVERY_NODE_URL" \
  --dart-define="GATEWAY_NODE_URL=$GATEWAY_NODE_URL" \
  --dart-define="FLUTTER_WEB_USE_SKIA=true"

echo ""
echo "=== Копируем в $OUT_DIR ==="
rm -rf "$OUT_DIR"
cp -r build/web "$OUT_DIR"

echo ""
echo "✓ Web build готов: $OUT_DIR"
echo "  Запустите: docker compose -p msng up -d msng-web"
echo "  Откройте:  http://localhost:3000"
