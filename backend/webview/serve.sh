#!/bin/sh
# Запускает локальный веб-сервер в корне project/, чтобы webview мог
# читать документы из ../spec через fetch (это не работает при
# открытии index.html напрямую как file://).
cd "$(dirname "$0")/.." || exit 1
PORT="${1:-8420}"
echo "Открой http://localhost:$PORT/webview/ в браузере"
python3 -m http.server "$PORT"
