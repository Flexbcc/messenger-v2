#!/bin/bash
# down.sh — остановить и опционально удалить данные
# Использование:
#   ./down.sh          — остановить контейнеры (данные сохраняются)
#   ./down.sh --clean  — остановить И удалить все данные (чистый старт)
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "=== Останавливаем msng-test ==="
docker compose -p msng down

if [ "$1" = "--clean" ]; then
  echo ""
  echo "⚠️  Удаляем все данные (./data/)..."
  read -p "Вы уверены? (y/N) " confirm
  if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
    rm -rf ./data/
    mkdir -p data/{core/{home,storage,media,media-meta,relay,turn,discovery,push},client-1/{home,storage,media,media-meta},client-2/{home,storage,media,media-meta},client-3/{home,storage,media,media-meta},storage-app}
    echo "✓ Данные удалены."
  else
    echo "Отменено."
  fi
fi
