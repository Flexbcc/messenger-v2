#!/usr/bin/env bash
# check-deploy.sh — проверяет health всех нод деплоя.
# Читает URLs из .env (или переменных окружения).
# Использование: bash scripts/check-deploy.sh [путь/к/.env]

set -euo pipefail

ENV_FILE="${1:-.env}"
[[ -f "$ENV_FILE" ]] && set -a && source "$ENV_FILE" && set +a

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
fail() { echo -e "  ${RED}✗${NC} $*"; FAILED=$((FAILED+1)); }
warn() { echo -e "  ${YELLOW}~${NC} $*"; }

FAILED=0
TIMEOUT=5

check_node() {
  local name="$1" url="$2"
  echo "── $name ($url)"
  if ! resp=$(curl -sf --max-time "$TIMEOUT" "${url}/health" 2>&1); then
    fail "недоступен (curl exit $?)"
    return
  fi
  # Версия / build_hash
  build=$(echo "$resp" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('build_hash','?'))" 2>/dev/null || echo "?")
  status=$(echo "$resp" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('status','?'))" 2>/dev/null || echo "?")

  if [[ "$status" == "ok" ]]; then
    ok "status=ok  build=${build}"
  else
    warn "status=${status}  build=${build}"
  fi

  # Дополнительные поля (federation counters, буфер и т.п.)
  extra=$(echo "$resp" | python3 -c "
import sys, json
d = json.load(sys.stdin)
parts = []
if 'load' in d:
    ld = d['load']
    if 'federation' in ld:
        fed = ld['federation']
        parts.append(f\"fed: direct={fed.get('direct_ok',0)} relay={fed.get('relay_ok',0)} buf={fed.get('buffer_ok',0)} fail={fed.get('failed',0)}\")
    if 'buffer_limit_per_recipient' in ld:
        parts.append(f\"buffer_limit={ld['buffer_limit_per_recipient']} evict={ld.get('buffer_eviction_policy','?')}\")
if parts:
    print('    ' + ' | '.join(parts))
" 2>/dev/null || true)
  [[ -n "$extra" ]] && echo -e "$extra"
}

echo ""
echo "═══════════════════════════════════════"
echo " Messenger deploy check  $(date '+%Y-%m-%d %H:%M:%S')"
echo "═══════════════════════════════════════"
echo ""

# Собираем список нод из переменных окружения
declare -A NODES
[[ -n "${DISCOVERY_NODE_URL:-}" ]]  && NODES["discovery-node"]="$DISCOVERY_NODE_URL"
[[ -n "${HOME_NODE_PUBLIC_URL:-}" ]] && NODES["home-node"]="$HOME_NODE_PUBLIC_URL"
[[ -n "${STORAGE_NODE_URL:-}" ]]    && NODES["storage-node"]="$STORAGE_NODE_URL"
[[ -n "${RELAY_NODE_PUBLIC_URL:-}" ]] && NODES["relay-node"]="$RELAY_NODE_PUBLIC_URL"
[[ -n "${MEDIA_NODE_PUBLIC_URL:-}" ]] && NODES["media-node"]="$MEDIA_NODE_PUBLIC_URL"
[[ -n "${TURN_NODE_PUBLIC_URL:-}" ]] && NODES["turn-node"]="$TURN_NODE_PUBLIC_URL"
[[ -n "${GATEWAY_NODE_PUBLIC_URL:-}" ]] && NODES["gateway-node"]="$GATEWAY_NODE_PUBLIC_URL"

if [[ ${#NODES[@]} -eq 0 ]]; then
  echo "Не найдены URL нод. Укажите .env или задайте переменные окружения."
  exit 1
fi

for name in discovery-node home-node storage-node relay-node media-node turn-node gateway-node; do
  [[ -n "${NODES[$name]:-}" ]] && check_node "$name" "${NODES[$name]}"
done

echo ""
echo "═══════════════════════════════════════"
if [[ $FAILED -eq 0 ]]; then
  echo -e " ${GREEN}Все ноды доступны${NC}"
else
  echo -e " ${RED}Недоступно нод: $FAILED${NC}"
fi
echo "═══════════════════════════════════════"
echo ""

exit $FAILED
