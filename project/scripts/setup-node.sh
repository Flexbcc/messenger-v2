#!/usr/bin/env bash
# Guided first-run setup for a lab machine: pick which node(s) this box runs,
# auto-detect its LAN IP, write .env, and start it with docker compose.
#
# Usage: ./scripts/setup-node.sh
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker не найден. Установите Docker (Desktop на macOS/Windows, docker-ce на Linux) и запустите скрипт снова." >&2
  exit 1
fi

detect_lan_ip() {
  if [[ "$(uname)" == "Darwin" ]]; then
    for iface in en0 en1; do
      ip=$(ipconfig getifaddr "$iface" 2>/dev/null || true)
      if [[ -n "$ip" ]]; then echo "$ip"; return; fi
    done
  else
    ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    if [[ -n "$ip" ]]; then echo "$ip"; return; fi
  fi
  echo ""
}

detected_ip=$(detect_lan_ip)

echo "=== Настройка ноды мессенджера ==="
echo
echo "Какую роль запускаем на этой машине?"
echo "  1) discovery   — главная нода мониторинга (одна на весь стенд)"
echo "  2) home        — регистрация/чаты/сообщения"
echo "  3) storage     — буфер офлайн-сообщений"
echo "  4) media       — файлы"
echo "  5) relay       — пересылка (fallback-доставка)"
echo "  6) turn        — TURN-креды для звонков"
echo "  7) admin       — Node Monitor (веб-дашборд)"
echo "  8) all         — весь стек локально, для теста на одной машине"
read -rp "Выбор [1-8]: " choice

read -rp "LAN IP этой машины${detected_ip:+ (Enter = $detected_ip)}: " this_ip
this_ip=${this_ip:-$detected_ip}
if [[ -z "$this_ip" ]]; then
  echo "Не удалось определить IP автоматически, и вы его не ввели. Прерываю." >&2
  exit 1
fi

if [[ "$choice" != "1" ]]; then
  read -rp "LAN IP главной ноды (discovery): " discovery_ip
  if [[ -z "$discovery_ip" ]]; then
    echo "IP discovery-node обязателен для всех ролей, кроме самой discovery." >&2
    exit 1
  fi
else
  discovery_ip="$this_ip"
fi

ENV_FILE=".env"
touch "$ENV_FILE"

set_var() {
  # Replaces an existing KEY=... line in .env, or appends it.
  local key="$1" value="$2"
  if grep -q "^${key}=" "$ENV_FILE" 2>/dev/null; then
    tmp=$(mktemp)
    awk -F= -v k="$key" -v v="$value" 'BEGIN{OFS="="} $1==k {print k,v; next} {print}' "$ENV_FILE" > "$tmp"
    mv "$tmp" "$ENV_FILE"
  else
    echo "${key}=${value}" >> "$ENV_FILE"
  fi
}

set_var "DISCOVERY_NODE_URL" "http://${discovery_ip}:8003"

service=""
case "$choice" in
  1)
    service="discovery-node"
    ;;
  2)
    service="home-node"
    set_var "HOME_NODE_ID" "home-$(hostname -s 2>/dev/null || echo 1)"
    set_var "HOME_NODE_PUBLIC_URL" "http://${this_ip}:8001"
    read -rp "LAN IP storage-node: " storage_ip
    set_var "STORAGE_NODE_URL" "http://${storage_ip}:8002"
    ;;
  3)
    service="storage-node"
    set_var "STORAGE_NODE_ID" "storage-$(hostname -s 2>/dev/null || echo 1)"
    set_var "STORAGE_NODE_PUBLIC_URL" "http://${this_ip}:8002"
    ;;
  4)
    service="media-node"
    set_var "MEDIA_NODE_ID" "media-$(hostname -s 2>/dev/null || echo 1)"
    set_var "MEDIA_NODE_PUBLIC_URL" "http://${this_ip}:8004"
    ;;
  5)
    service="relay-node"
    set_var "RELAY_NODE_ID" "relay-$(hostname -s 2>/dev/null || echo 1)"
    set_var "RELAY_NODE_PUBLIC_URL" "http://${this_ip}:8005"
    ;;
  6)
    service="turn-node"
    set_var "TURN_NODE_ID" "turn-$(hostname -s 2>/dev/null || echo 1)"
    set_var "TURN_NODE_PUBLIC_URL" "http://${this_ip}:8006"
    ;;
  7)
    service="admin"
    ;;
  8)
    service=""
    set_var "HOME_NODE_PUBLIC_URL" "http://${this_ip}:8001"
    set_var "STORAGE_NODE_URL" "http://${this_ip}:8002"
    set_var "STORAGE_NODE_PUBLIC_URL" "http://${this_ip}:8002"
    set_var "MEDIA_NODE_PUBLIC_URL" "http://${this_ip}:8004"
    set_var "RELAY_NODE_PUBLIC_URL" "http://${this_ip}:8005"
    set_var "TURN_NODE_PUBLIC_URL" "http://${this_ip}:8006"
    ;;
  *)
    echo "Неизвестный выбор: $choice" >&2
    exit 1
    ;;
esac

echo
echo "Записал настройки в .env. Поднимаю ${service:-весь стек}..."
if [[ -n "$service" ]]; then
  docker compose up -d --build "$service"
else
  docker compose up -d --build
fi

echo
echo "Готово. Проверить: docker compose ps"
echo "Логи:                docker compose logs -f ${service}"
