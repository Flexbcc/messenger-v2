#!/bin/bash
# health.sh — проверить что все ноды живы
set -e

check() {
  local name="$1"
  local url="$2"
  local status
  # curl при неудаче печатает 000 И возвращает ненулевой код,
  # поэтому подстановку через || делать нельзя — получится "000ERR".
  status=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 "$url" 2>/dev/null) || true
  case "$status" in
    200)     echo "  ✓ $name ($url)" ;;
    000|"")  echo "  ✗ $name ($url) — не отвечает" ;;
    *)       echo "  ✗ $name ($url) — HTTP $status" ;;
  esac
}

echo "=== msng-test health check ==="
echo ""
echo "Infrastructure:"
check "Discovery"       "http://localhost:8103/health"

echo ""
echo "Core node:"
check "core-home"       "http://localhost:8001/health"
check "core-media"      "http://localhost:8004/health"
check "core-turn"       "http://localhost:8006/health"

echo ""
echo "Client nodes:"
check "client-1-home"   "http://localhost:8011/health"
check "client-1-media"  "http://localhost:8014/health"
check "client-2-home"   "http://localhost:8022/health"
check "client-2-media"  "http://localhost:8024/health"
check "client-3-home"   "http://localhost:8031/health"
check "client-3-media"  "http://localhost:8034/health"

echo ""
echo "Storage App:"
check "storage-app"     "http://localhost:8042/health"

echo ""
echo "Админка:"
status=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 "http://127.0.0.1:9210/health" 2>/dev/null) || true
case "$status" in
  200)    echo "  ✓ http://127.0.0.1:9210" ;;
  403|401) echo "  ✗ 9210 → HTTP $status (нужен ADMIN_PANEL_SECRET?)" ;;
  000|"") echo "  ✗ 9210 не отвечает — ./up.sh admin" ;;
  *)      echo "  ✗ 9210 → HTTP $status" ;;
esac

echo ""
echo "Web:"
status=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 "http://localhost:3000" 2>/dev/null) || true
case "$status" in
  200)    echo "  ✓ Web client (http://localhost:3000)" ;;
  403)    echo "  ✗ Web client — 403: папка web-build пуста, запустите ./build-web.sh" ;;
  000|"") echo "  ✗ Web client — не отвечает" ;;
  *)      echo "  ✗ Web client — HTTP $status" ;;
esac

##############################################################################
# Проверка изоляции админки
#
# Клиентская нода не должна видеть админку даже изнутри Docker-сети.
##############################################################################
echo ""
echo "Изоляция шлюза оператора:"

if ! docker ps --format '{{.Names}}' | grep -q '^msng-client-1-home$'; then
  echo "  … client-1-home не запущен, проверка пропущена"
else
  # Пытаемся достучаться до админки из контейнера клиентской ноды.
  # Ожидаем провал — значит сегментация работает.
  if docker exec msng-client-1-home \
       python3 -c "
import socket, sys
s = socket.socket()
s.settimeout(3)
try:
    s.connect(('msng-operator-gw', 9443))
    sys.exit(0)   # достучались — плохо
except Exception:
    sys.exit(1)   # не достучались — хорошо
" 2>/dev/null; then
    echo "  ✗ ОПАСНО: клиентская нода видит шлюз оператора!"
    echo "    Проверьте секцию networks в docker-compose.yml"
  else
    echo "  ✓ клиентская нода не видит шлюз оператора"
  fi

  # Админка не должна быть доступна с внешнего интерфейса хоста
  HOST_IP=$(ipconfig getifaddr en0 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}')
  if [ -n "$HOST_IP" ]; then
    ext=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 2 "https://$HOST_IP:9443/health" 2>/dev/null) || true
    if [ "$ext" = "200" ]; then
      echo "  ✗ ОПАСНО: шлюз пустил без сертификата с $HOST_IP:9443"
    else
      echo "  ✓ шлюз требует сертификат и снаружи ($HOST_IP:9443 → $ext)"
    fi
  fi
fi
