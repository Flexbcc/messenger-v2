#!/bin/bash
# client-node update — обновление без остановки сервисов
set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[✗]${NC} $*"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"

cd "$ROOT"

[ -f .env ] || error ".env не найден. Запустите сначала: ./scripts/setup.sh"

echo ""
echo "── client-node update ──────────────────"
echo ""

# Обновляем исходники
info "Обновляем исходники (git pull)..."
cd "$(dirname "$ROOT")"
git pull --ff-only || warn "git pull не удался — продолжаем с текущим кодом"
cd "$ROOT"

# Пересобираем образы и перезапускаем без downtime
info "Пересборка образов..."
docker compose build --pull

info "Перезапуск сервисов (rolling)..."
docker compose up -d --no-deps --remove-orphans

# Проверка здоровья
sleep 5
info "Проверка здоровья нод..."
bash "$SCRIPT_DIR/health-check.sh"

echo ""
info "Обновление завершено."
