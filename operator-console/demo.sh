#!/usr/bin/env bash
# demo.sh — посмотреть пульт без серверов, сертификатов и Docker.
#
# Данные выдуманные, наружу ничего не уходит. Нужен только Python 3.
set -euo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

command -v python3 >/dev/null || { echo "✗ Нужен python3"; exit 1; }

# Открыть браузер, когда сервер поднимется
( sleep 1.5
  if command -v open >/dev/null; then open http://127.0.0.1:9301
  elif command -v xdg-open >/dev/null; then xdg-open http://127.0.0.1:9301
  fi ) &

exec python3 demo_server.py
