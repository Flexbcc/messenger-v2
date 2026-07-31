#!/bin/bash
# Проверка здоровья всех нод client-node
set -euo pipefail

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
fail() { echo -e "  ${RED}✗${NC} $*"; FAILED=1; }
warn() { echo -e "  ${YELLOW}~${NC} $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
cd "$ROOT"

[ -f .env ] && source .env 2>/dev/null || true

FAILED=0

echo ""
echo "── health check ────────────────────────"

check() {
    local name="$1" url="$2"
    local status
    status=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 5 "$url" 2>/dev/null || echo "000")
    if [ "$status" = "200" ]; then
        ok "$name ($url)"
    else
        fail "$name ($url) — HTTP $status"
    fi
}

# Напрямую внутрь контейнера (минуя nginx — /health закрыт снаружи на порту 443/8444/8446/8447)
check_internal() {
    local name="$1" svc="$2" port="$3"
    local status
    status=$(docker compose exec -T "$svc" \
        wget -qO- --server-response "http://localhost:${port}/health" 2>&1 \
        | awk '/HTTP\//{print $2}' | tail -1 || echo "000")
    if [ "$status" = "200" ]; then
        ok "$name (internal :$port)"
    else
        fail "$name (internal :$port) — HTTP $status"
    fi
}

check_internal "home-node"    home-node    8001
check_internal "media-node"   media-node   8004
check_internal "turn-node"    turn-node    8006
check_internal "gateway-node" gateway-node 8007

# storage и relay — internal, проверяем через docker
for svc in storage-node relay-node; do
    if docker compose ps --status running "$svc" 2>/dev/null | grep -q "$svc"; then
        ok "$svc (running)"
    else
        fail "$svc (not running)"
    fi
done

# coturn
if docker compose ps --status running coturn 2>/dev/null | grep -q coturn; then
    ok "coturn (running)"
else
    warn "coturn (not running — звонки работают только в LAN)"
fi

echo ""
if [ "$FAILED" -eq 0 ]; then
    echo -e "${GREEN}Все ноды в норме.${NC}"
else
    echo -e "${RED}Есть проблемы — см. выше.${NC}"
    exit 1
fi
