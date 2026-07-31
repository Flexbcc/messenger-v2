#!/usr/bin/env bash
###############################################################################
# fix-port.sh — найти и освободить занятый порт
#
#   ./fix-port.sh 9210          — показать, кто держит
#   ./fix-port.sh 9210 --free   — попытаться освободить
#
# Освобождает только контейнеры Docker. Системные процессы (launchd и
# подобные) не трогает — их порт нужно обходить, а не отбирать.
###############################################################################
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PORT="${1:-}"
FREE=0
[ "${2:-}" = "--free" ] && FREE=1

if [ -z "$PORT" ]; then
  echo "Использование: ./fix-port.sh <порт> [--free]"
  exit 1
fi

port_open() { (exec 3<>/dev/tcp/127.0.0.1/"$1") 2>/dev/null && exec 3<&- && return 0 || return 1; }

echo "═══ Порт $PORT ═══"
echo ""

if ! port_open "$PORT"; then
  echo "  ✓ свободен"
  exit 0
fi

echo "  занят. Разбираемся кем:"
echo ""

# ── 1. Запущенные контейнеры ────────────────────────────────────────────────
running=$(docker ps --filter "publish=$PORT" --format '{{.Names}}\t{{.Image}}\t{{.Status}}' 2>/dev/null)
if [ -n "$running" ]; then
  echo "  Запущенные контейнеры:"
  echo "$running" | sed 's/^/    /'
  echo ""
fi

# ── 2. Остановленные, но занимающие порт ────────────────────────────────────
all=$(docker ps -a --filter "publish=$PORT" --format '{{.Names}}\t{{.State}}' 2>/dev/null)
if [ -n "$all" ]; then
  echo "  Все контейнеры с этим портом:"
  echo "$all" | sed 's/^/    /'
  echo ""
fi

# ── 3. Процесс на хосте ─────────────────────────────────────────────────────
proc=$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | awk 'NR>1 {print "    "$1" pid="$2" user="$3}' | sort -u)
if [ -n "$proc" ]; then
  echo "  Процессы (по данным lsof):"
  echo "$proc"
  echo ""
else
  echo "  lsof ничего не показал — возможно процесс чужого пользователя."
  echo "  Повторите с правами: sudo lsof -nP -iTCP:$PORT -sTCP:LISTEN"
  echo ""
fi

# ── 4. Освобождение ─────────────────────────────────────────────────────────
if [ "$FREE" != "1" ]; then
  echo "  Освободить (только контейнеры):  ./fix-port.sh $PORT --free"
  exit 0
fi

echo "═══ Освобождаю ═══"
echo ""

freed=0

# Осиротевшие контейнеры проекта msng
orphans=$(docker ps -a --filter "publish=$PORT" --format '{{.Names}}' 2>/dev/null | grep '^msng-' || true)
for c in $orphans; do
  echo "  останавливаю $c"
  docker rm -f "$c" >/dev/null 2>&1 && freed=1
done

# Прочие контейнеры — только с подтверждения
others=$(docker ps -a --filter "publish=$PORT" --format '{{.Names}}' 2>/dev/null | grep -v '^msng-' || true)
for c in $others; do
  read -p "  Удалить чужой контейнер «$c»? (y/N) " ans
  if [ "$ans" = "y" ] || [ "$ans" = "Y" ]; then
    docker rm -f "$c" >/dev/null 2>&1 && freed=1
  fi
done

sleep 1

echo ""
if port_open "$PORT"; then
  echo "  ✗ порт всё ещё занят."
  echo ""
  echo "  Если его держит системный процесс (launchd и подобные) —"
  echo "  отбирать не стоит. Смените порт в .env:"
  echo ""
  echo "      cp .env.example .env"
  echo "      # раскомментируйте нужную строку, например:"
  echo "      PORT_ADMIN=9310"
  echo ""
  exit 1
else
  [ "$freed" = "1" ] && echo "  ✓ порт освобождён" || echo "  ✓ порт свободен"
fi
