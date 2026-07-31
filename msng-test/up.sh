#!/bin/bash
# up.sh — поднять весь msng-test стек
# Использование:
#   ./up.sh          — поднять всё
#   ./up.sh core     — только core-нода
#   ./up.sh client-1 — только client-1
#   ./up.sh web      — только web
#   ./up.sh admin    — только админка
#   ./up.sh gateway  — mTLS-шлюз (нужен лишь для удалённого сервера)
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

MODE="${1:-all}"

##############################################################################
# Предполётная проверка портов
#
# Если порт занят, docker compose падает на середине и часть контейнеров
# остаётся поднятой, а часть нет. Проще проверить заранее и сказать, кто
# именно держит порт.
##############################################################################
# Признак занятости — принимается ли TCP-соединение. Это надёжнее lsof,
# который без root не показывает процессы других пользователей.
port_open() { (exec 3<>/dev/tcp/127.0.0.1/"$1") 2>/dev/null && exec 3<&- && return 0 || return 1; }

# Читаем .env — иначе проверяем не те порты, что реально будут проброшены.
# Именно так и вышло: пользователь сменил PORT_ADMIN, а скрипт продолжал
# ругаться на старый порт.
if [ -f .env ]; then
  set -a
  . ./.env
  set +a
fi

# Порты берём из тех же переменных, что и docker-compose.yml
PORTS="
${PORT_DISCOVERY:-8103}
${PORT_CORE_HOME:-8001}
${PORT_CORE_MEDIA:-8004}
${PORT_CORE_TURN:-8006}
${PORT_C1_HOME:-8011}
${PORT_C1_MEDIA:-8014}
${PORT_C2_HOME:-8022}
${PORT_C2_MEDIA:-8024}
${PORT_C3_HOME:-8031}
${PORT_C3_MEDIA:-8034}
${PORT_STORAGE_APP:-8042}
${PORT_WEB:-3000}
${PORT_ADMIN:-9210}
"

BUSY=""
for p in $PORTS; do
  port_open "$p" || continue
  if docker ps --filter "publish=$p" --format '{{.Names}}' 2>/dev/null | grep -q '^msng-'; then
    continue
  fi
  other=$(docker ps --filter "publish=$p" --format '{{.Names}}' 2>/dev/null | head -1)
  proc=$(lsof -nP -iTCP:"$p" -sTCP:LISTEN 2>/dev/null | awk 'NR==2 {print $1" (pid "$2")"}')
  BUSY="$BUSY\n  $p — ${other:-${proc:-владелец не определён}}"
done

if [ -n "$BUSY" ]; then
  echo "✗ Порты заняты — стек поднимется частично и оборвётся:"
  printf "$BUSY\n"
  echo ""
  echo "Чаще всего это старый стек:"
  echo "    cd ../project && docker compose down"
  echo ""
  echo "Найти владельца и, если это системный процесс, сменить порт:"
  echo "    ./fix-port.sh <порт>"
  echo "    # затем в .env:  PORT_ADMIN=9310  (или другой свободный)"
  echo ""
  echo "Иногда порт удерживает сам Docker Desktop после сбойного запуска."
  echo "Тогда помогает:"
  echo "    docker compose -p msng down --remove-orphans"
  echo "    # и, если не отпустило, перезапуск Docker Desktop"
  echo ""
  exit 1
fi

# Убедимся что web-build существует (иначе msng-web упадёт)
if [ ! -d "$SCRIPT_DIR/web-build" ]; then
  echo "⚠️  web-build не найден. Запустите ./build-web.sh сначала."
  echo "   Продолжаем без msng-web..."
  WEB_EXCLUDE="--scale msng-web=0"
else
  WEB_EXCLUDE=""
fi

case "$MODE" in
  core)
    echo "=== Поднимаем core-ноду ==="
    docker compose -p msng up -d --build \
      msng-discovery \
      msng-core-home msng-core-storage msng-core-media \
      msng-core-relay msng-core-turn msng-core-push
    ;;
  client-1)
    docker compose -p msng up -d --build \
      msng-client-1-home msng-client-1-storage msng-client-1-media
    ;;
  client-2)
    docker compose -p msng up -d --build \
      msng-client-2-home msng-client-2-storage msng-client-2-media
    ;;
  client-3)
    docker compose -p msng up -d --build \
      msng-client-3-home msng-client-3-storage msng-client-3-media
    ;;
  web)
    docker compose -p msng up -d msng-web
    ;;
  admin)
    echo "=== Поднимаем админку (только 127.0.0.1) ==="
    docker compose -p msng up -d --build msng-admin
    ;;
  gateway)
    echo "=== Поднимаем mTLS-шлюз (для удалённого доступа) ==="
    docker compose -p msng --profile remote up -d msng-operator-gw
    ;;
  storage-app)
    docker compose -p msng up -d --build msng-storage-app
    ;;
  all)
    echo "=== Поднимаем весь msng-test стек ==="
    # --remove-orphans убирает контейнеры от прежних версий этого файла:
    # они остаются в проекте и продолжают держать порты.
    docker compose -p msng up -d --build --remove-orphans $WEB_EXCLUDE
    ;;
esac

echo ""
echo "=== Статус ==="
docker compose -p msng ps
echo ""
echo "Порты:"
echo "  Discovery:        http://localhost:${PORT_DISCOVERY:-8103}"
echo "  Core home:        http://localhost:${PORT_CORE_HOME:-8001}"
echo "  Core media:       http://localhost:${PORT_CORE_MEDIA:-8004}"
echo "  Core turn:        http://localhost:${PORT_CORE_TURN:-8006}"
echo "  Client-1 home:    http://localhost:${PORT_C1_HOME:-8011}"
echo "  Client-2 home:    http://localhost:${PORT_C2_HOME:-8022}"
echo "  Client-3 home:    http://localhost:${PORT_C3_HOME:-8031}"
echo "  Storage App:      http://localhost:${PORT_STORAGE_APP:-8042}"
echo "  Web client:       http://localhost:${PORT_WEB:-3000}"
echo ""
echo "  ▸ АДМИНКА:        http://127.0.0.1:${PORT_ADMIN:-9210}"
