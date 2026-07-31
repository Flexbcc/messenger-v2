#!/usr/bin/env bash
###############################################################################
# diag.sh — собрать всё о состоянии стека одним запуском
#
# Показывает: статус каждого контейнера, причину падения, последние строки
# логов упавших, занятые порты и что создалось на диске.
#
#   ./diag.sh            — краткая сводка
#   ./diag.sh --logs     — плюс логи всех проблемных контейнеров
###############################################################################
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

WITH_LOGS=0
[ "${1:-}" = "--logs" ] && WITH_LOGS=1

hr() { printf '─%.0s' $(seq 72); echo; }


echo "════════════════════════════════════════════════════════════════════════"
echo "  Диагностика msng-test"
echo "════════════════════════════════════════════════════════════════════════"

##############################################################################
# 0. Импорты — до всякого Docker
#
# Забытый импорт валит ноду при старте, но выглядит как «контейнер
# перезапускается». Проверить это можно за секунду, без пересборки.
##############################################################################
if [ -f ../project/scripts/check-imports.py ]; then
  echo ""
  echo "▸ ИМПОРТЫ (статическая проверка)"
  hr
  if out=$(python3 ../project/scripts/check-imports.py 2>&1); then
    echo "  ✓ необъявленных имён нет"
  else
    echo "$out" | sed 's/^/  /'
    echo ""
    echo "  ⚠️  Эти модули упадут при импорте — ноды не поднимутся."
    echo "     Исправьте импорты, затем: ./up.sh"
  fi
fi

##############################################################################
# 1. Кто должен быть и кто есть
##############################################################################
echo ""
echo "▸ КОНТЕЙНЕРЫ"
hr

EXPECTED=$(docker compose -p msng config --services 2>/dev/null | sort)
[ -z "$EXPECTED" ] && { echo "  ✗ docker compose config не читается — ошибка в docker-compose.yml"; docker compose -p msng config -q; exit 1; }

printf "  %-24s %-12s %-10s %s\n" "СЕРВИС" "СОСТОЯНИЕ" "КОД" "ПРИЧИНА"
printf "  %-24s %-12s %-10s %s\n" "──────" "─────────" "───" "───────"

MISSING=""
BROKEN=""

for svc in $EXPECTED; do
  cid=$(docker ps -aq --filter "name=^${svc}$" 2>/dev/null | head -1)

  if [ -z "$cid" ]; then
    printf "  %-24s %-12s %-10s %s\n" "$svc" "НЕТ" "—" "контейнер не создан"
    MISSING="$MISSING $svc"
    continue
  fi

  state=$(docker inspect -f '{{.State.Status}}' "$cid" 2>/dev/null)
  code=$(docker inspect -f '{{.State.ExitCode}}' "$cid" 2>/dev/null)
  err=$(docker inspect -f '{{.State.Error}}' "$cid" 2>/dev/null)
  restarts=$(docker inspect -f '{{.RestartCount}}' "$cid" 2>/dev/null)
  health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$cid" 2>/dev/null)

  reason=""
  case "$state" in
    running)
      [ -n "$health" ] && reason="health: $health"
      [ "${restarts:-0}" -gt 0 ] && reason="перезапусков: $restarts"
      ;;
    restarting) reason="ПАДАЕТ И ПЕРЕЗАПУСКАЕТСЯ (${restarts} раз)"; BROKEN="$BROKEN $svc" ;;
    created)    reason="создан, но не запускался" ; BROKEN="$BROKEN $svc" ;;
    exited)     reason="${err:-завершился}"       ; BROKEN="$BROKEN $svc" ;;
    *)          reason="$err" ;;
  esac

  printf "  %-24s %-12s %-10s %s\n" "$svc" "$state" "${code:-—}" "$reason"
done

##############################################################################
# 2. Порты
##############################################################################
echo ""
echo "▸ ПОРТЫ"
hr
# Проверяем несколькими способами: lsof может не показать чужой процесс
# без root, docker ps — только запущенные контейнеры. Опорный признак —
# реально ли принимается TCP-соединение на порт.
port_open() { (exec 3<>/dev/tcp/127.0.0.1/"$1") 2>/dev/null && exec 3<&- && return 0 || return 1; }

CONFLICTS=0
for p in 8103 8001 8004 8006 8011 8014 8022 8024 8031 8034 8042 3000 9443 9444; do
  port_open "$p" || continue          # порт свободен — идём дальше

  # Кто из НАШИХ его слушает (running-контейнер с таким портом)
  ours=$(docker ps --filter "publish=$p" --format '{{.Names}}' 2>/dev/null | grep '^msng-' | head -1)
  if [ -n "$ours" ]; then
    continue                          # наш работающий контейнер — норма
  fi

  # Порт занят, но не нашим running-контейнером — разбираемся кем
  other=$(docker ps --filter "publish=$p" --format '{{.Names}} ({{.Image}})' 2>/dev/null | head -1)
  proc=$(lsof -nP -iTCP:"$p" -sTCP:LISTEN 2>/dev/null | awk 'NR==2 {print $1" pid="$2" ("$3")"}')

  CONFLICTS=$((CONFLICTS + 1))
  if [ -n "$other" ]; then
    printf "  ✗ %-6s чужой контейнер: %s\n" "$p" "$other"
  elif [ -n "$proc" ]; then
    printf "  ✗ %-6s процесс: %s\n" "$p" "$proc"
  else
    printf "  ✗ %-6s занят, но владелец не определяется\n" "$p"
    printf "         (вероятно процесс другого пользователя — нужен sudo lsof)\n"
  fi

  # Есть ли наш контейнер на этот порт, который НЕ смог запуститься
  stuck=$(docker ps -a --filter "publish=$p" --format '{{.Names}} [{{.State}}]' 2>/dev/null | grep '^msng-' | head -1)
  [ -n "$stuck" ] && printf "         из-за этого не стартовал: %s\n" "$stuck"
done

if [ "$CONFLICTS" -eq 0 ]; then
  echo "  ✓ конфликтов нет"
else
  echo ""
  echo "  Найти виновника вручную:"
  echo "      sudo lsof -nP -iTCP:8022 -sTCP:LISTEN"
  echo "      docker ps -a --filter publish=8022"
fi


##############################################################################
# 3. Данные на диске — кто дошёл до создания БД
##############################################################################
echo ""
echo "▸ ДАННЫЕ"
hr
for d in core/home core/storage core/media-meta core/relay discovery \
         client-1/home client-2/home client-3/home; do
  n=$(find "data/$d" -type f 2>/dev/null | wc -l | tr -d ' ')
  if [ "$n" -gt 0 ]; then
    printf "  ✓ %-22s %s файлов\n" "$d" "$n"
  else
    printf "  ✗ %-22s пусто — сервис не дошёл до создания БД\n" "$d"
  fi
done

##############################################################################
# 4. Логи проблемных
##############################################################################
if [ -n "$BROKEN" ]; then
  echo ""
  echo "▸ ЛОГИ ПРОБЛЕМНЫХ КОНТЕЙНЕРОВ"
  hr
  LINES=$([ "$WITH_LOGS" = "1" ] && echo 60 || echo 15)
  for svc in $BROKEN; do
    echo ""
    echo "  ── $svc ────────────────────────────────────────────"
    docker logs --tail "$LINES" "$svc" 2>&1 | sed 's/^/    /' | tail -"$LINES"
  done
fi

##############################################################################
# 5. Вывод
##############################################################################
echo ""
echo "▸ ИТОГ"
hr
if [ -n "$MISSING" ]; then
  echo "  Не созданы:$MISSING"
  echo ""
  echo "  Обычно это значит, что docker compose прервался на середине —"
  echo "  чаще всего из-за занятого порта. Освободите порт и поднимите заново:"
  echo ""
  echo "      cd ../project && docker compose down"
  echo "      cd ../msng-test && ./up.sh"
  echo ""
elif [ -n "$BROKEN" ]; then
  echo "  Падают:$BROKEN"
  echo ""
  echo "  Смотрите логи выше. Полные логи одного сервиса:"
  echo "      docker compose -p msng logs <сервис> --tail=100"
  echo ""
else
  echo "  ✓ Все контейнеры на месте и работают."
  echo ""
  echo "  Проверить эндпоинты:  ./health.sh"
  echo ""
fi
