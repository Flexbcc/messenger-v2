#!/bin/sh
###############################################################################
# Точка входа mTLS-шлюза оператора.
#
# Вынесено в отдельный файл, а не в command: внутри docker-compose.yml —
# YAML схлопывает переносы строк, и многострочный shell с циклами и
# кавычками ломается ещё до запуска.
#
# Делает две вещи:
#   1. Подставляет переменные окружения в шаблон конфига
#   2. Ждёт, пока апстримы появятся в DNS
#
# Второе обязательно: nginx резолвит имена из upstream при старте и падает
# с «host not found», если контейнера ещё нет. depends_on гарантирует лишь
# создание контейнера, но не готовность сервиса внутри него.
###############################################################################
set -e

TEMPLATE=/etc/nginx/templates/nginx.conf.template
TARGET=/etc/nginx/nginx.conf

# Только наши переменные — nginx-овские ($host, $ssl_client_s_dn и прочие)
# должны остаться нетронутыми
envsubst '$DISCOVERY_ADMIN_SECRET $DISCOVERY_UPSTREAM $HOME_UPSTREAM' \
  < "$TEMPLATE" > "$TARGET"

# Имя хоста без порта — для проверки в DNS
discovery_host="${DISCOVERY_UPSTREAM%%:*}"
home_host="${HOME_UPSTREAM%%:*}"

echo "[gw] жду апстримы: $discovery_host, $home_host"

i=0
while [ "$i" -lt 60 ]; do
  if getent hosts "$discovery_host" >/dev/null 2>&1 &&
     getent hosts "$home_host" >/dev/null 2>&1; then
    echo "[gw] апстримы доступны, запускаю nginx"
    exec nginx -g 'daemon off;'
  fi
  i=$((i + 1))
  echo "[gw] ожидаю… ($i/60)"
  sleep 2
done

echo "[gw] апстримы не появились за 120 секунд:"
echo "[gw]   $discovery_host — $(getent hosts "$discovery_host" >/dev/null 2>&1 && echo есть || echo нет)"
echo "[gw]   $home_host — $(getent hosts "$home_host" >/dev/null 2>&1 && echo есть || echo нет)"
echo "[gw] Проверьте, что эти контейнеры запущены и в сети msng-admin-net."
exit 1
