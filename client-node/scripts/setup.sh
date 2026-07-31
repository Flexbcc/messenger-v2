#!/bin/bash
# client-node setup — интерактивная настройка перед первым запуском
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()    { echo -e "${GREEN}[✓]${NC} $*"; }
warn()    { echo -e "${YELLOW}[!]${NC} $*"; }
error()   { echo -e "${RED}[✗]${NC} $*"; exit 1; }
prompt()  { echo -e "${YELLOW}[?]${NC} $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"

echo ""
echo "╔══════════════════════════════════════╗"
echo "║     client-node — первоначальная     ║"
echo "║           настройка                  ║"
echo "╚══════════════════════════════════════╝"
echo ""

# Проверки
command -v docker >/dev/null 2>&1 || error "Docker не установлен. https://docs.docker.com/get-docker/"
docker compose version >/dev/null 2>&1 || error "Docker Compose (v2) не установлен."

cd "$ROOT"

# Копируем .env если нет
if [ -f .env ]; then
    warn ".env уже существует — пропускаем создание"
else
    cp .env.example .env
    info "Создан .env из .env.example"
fi

echo ""
echo "── Основные параметры ──────────────────"
echo ""

# DISCOVERY_NODE_URL
prompt "Адрес discovery-ноды оператора (например http://1.2.3.4:8003):"
read -r DISCOVERY_URL
if [ -z "$DISCOVERY_URL" ]; then
    error "DISCOVERY_NODE_URL обязателен"
fi
sed -i.bak "s|DISCOVERY_NODE_URL=.*|DISCOVERY_NODE_URL=${DISCOVERY_URL}|" .env

# VPS IP
prompt "Публичный IP вашего VPS (например 5.6.7.8):"
read -r VPS_IP
if [ -z "$VPS_IP" ]; then
    error "Публичный IP обязателен"
fi
sed -i.bak "s|HOME_NODE_PUBLIC_URL=.*|HOME_NODE_PUBLIC_URL=https://${VPS_IP}|" .env
sed -i.bak "s|MEDIA_NODE_PUBLIC_URL=.*|MEDIA_NODE_PUBLIC_URL=https://${VPS_IP}:8444|" .env
sed -i.bak "s|TURN_NODE_PUBLIC_URL=.*|TURN_NODE_PUBLIC_URL=https://${VPS_IP}:8446|" .env
sed -i.bak "s|GATEWAY_NODE_PUBLIC_URL=.*|GATEWAY_NODE_PUBLIC_URL=https://${VPS_IP}:8447|" .env
sed -i.bak "s|TURN_SERVER_HOST=.*|TURN_SERVER_HOST=${VPS_IP}|" .env

# Обновляем coturn конфиг
sed -i.bak "s|external-ip=YOUR_VPS_IP|external-ip=${VPS_IP}|" config/coturn/turnserver.conf

# CLUSTER_ID
prompt "Имя вашей ноды (латиница, без пробелов, например: alice-node):"
read -r CLUSTER_NAME
CLUSTER_NAME="${CLUSTER_NAME:-client-1}"
sed -i.bak "s|CLUSTER_ID=.*|CLUSTER_ID=${CLUSTER_NAME}|" .env
sed -i.bak "s|HOME_NODE_ID=.*|HOME_NODE_ID=home-${CLUSTER_NAME}|" .env
sed -i.bak "s|STORAGE_NODE_ID=.*|STORAGE_NODE_ID=storage-${CLUSTER_NAME}|" .env
sed -i.bak "s|RELAY_NODE_ID=.*|RELAY_NODE_ID=relay-${CLUSTER_NAME}|" .env
sed -i.bak "s|MEDIA_NODE_ID=.*|MEDIA_NODE_ID=media-${CLUSTER_NAME}|" .env
sed -i.bak "s|TURN_NODE_ID=.*|TURN_NODE_ID=turn-${CLUSTER_NAME}|" .env
sed -i.bak "s|GATEWAY_NODE_ID=.*|GATEWAY_NODE_ID=gateway-${CLUSTER_NAME}|" .env

# Генерируем секреты
info "Генерируем JWT_SECRET и TURN_SHARED_SECRET..."
JWT_SECRET=$(openssl rand -hex 32)
TURN_SECRET=$(openssl rand -hex 32)
sed -i.bak "s|JWT_SECRET=.*|JWT_SECRET=${JWT_SECRET}|" .env
sed -i.bak "s|TURN_SHARED_SECRET=.*|TURN_SHARED_SECRET=${TURN_SECRET}|" .env
sed -i.bak "s|TURN_SHARED_SECRET_PLACEHOLDER|${TURN_SECRET}|" config/coturn/turnserver.conf

rm -f .env.bak config/coturn/turnserver.conf.bak

# Генерируем TLS сертификат
info "Генерируем self-signed TLS сертификат..."
bash "$SCRIPT_DIR/gen-cert.sh"

echo ""
echo "── ENROLLMENT_MODE ──────────────────────"
warn "Уточните у оператора режим enrollment:"
echo "  1) legacy  — открытая сеть, сразу trusted"
echo "  2) strict  — требуется одобрение оператора"
echo "  3) hybrid  — новые pending, уже approved остаются"
prompt "Выбор [1/2/3, default=1]:"
read -r ENROLL_CHOICE
case "$ENROLL_CHOICE" in
    2) ENROLL="strict" ;;
    3) ENROLL="hybrid" ;;
    *) ENROLL="legacy" ;;
esac
sed -i.bak "s|ENROLLMENT_MODE=.*|ENROLLMENT_MODE=${ENROLL}|" .env && rm -f .env.bak

echo ""
info "Конфигурация сохранена в .env"
echo ""
echo "── Необходимые порты в firewall ────────"
echo "  TCP: 8001 (home), 8004 (media), 8006 (turn-api), 8007 (gateway)"
echo "  UDP: 3478 (coturn STUN/TURN), 49152-65535 (медиапотоки)"
echo ""

prompt "Запустить ноды сейчас? [y/N]:"
read -r START
if [[ "$START" =~ ^[Yy]$ ]]; then
    echo ""
    info "Сборка и запуск..."
    docker compose up -d --build
    echo ""
    info "Ноды запущены. Проверка:"
    sleep 3
    bash "$SCRIPT_DIR/health-check.sh" || true
else
    echo ""
    info "Готово. Для запуска:"
    echo "  cd $(basename "$ROOT") && docker compose up -d --build"
fi
