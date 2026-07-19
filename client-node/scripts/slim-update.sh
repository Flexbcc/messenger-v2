#!/usr/bin/env bash
# slim-update.sh — обновление КЛИЕНТСКОЙ ноды без git и node.profile.
#
# Зачем: node-update.sh/update-node.sh рассчитаны на project/-layout
# (config/deploy/node.profile + git-репозиторий) и в slim-сборке не работают.
# Этот скрипт самодостаточен: пересобирает docker-compose сервисы из файлов на
# диске, проверяет здоровье home-node и откатывается на прежние образы при сбое.
#
# Использование:
#   ./scripts/slim-update.sh                 # пересобрать и перезапустить всё
#   ./scripts/slim-update.sh home-node       # только один сервис
#   RELEASE_ENV=./release.env ./scripts/slim-update.sh   # применить env релиза
#
# Шаги (см. ouo-settings-web-spec/docs/update-security.md):
#   1) применить release env (опц.)  2) снапшот текущих образов (rollback point)
#   3) rebuild --pull  4) up -d  5) health-check  6) авто-откат при неудаче
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

# --- docker compose (v2 plugin или legacy) ---
if docker compose version >/dev/null 2>&1; then
  DC=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
  DC=(docker-compose)
else
  echo "ОШИБКА: не найден docker compose." >&2
  exit 1
fi

[[ -f docker-compose.yml ]] || { echo "ОШИБКА: нет docker-compose.yml в $ROOT" >&2; exit 1; }

# --- целевые сервисы ---
if [[ $# -gt 0 ]]; then
  SERVICES=("$@")
else
  mapfile -t SERVICES < <("${DC[@]}" config --services)
fi
echo "Сервисы: ${SERVICES[*]}"

# --- 1) release env (опционально) ---
set_var() {  # key value — идемпотентная запись в .env
  local key="$1" value="$2" env_file="$ROOT/.env"
  touch "$env_file"
  if grep -q "^${key}=" "$env_file" 2>/dev/null; then
    local tmp; tmp=$(mktemp)
    awk -F= -v k="$key" -v v="$value" 'BEGIN{OFS="="} $1==k{print k,v;next}{print}' "$env_file" > "$tmp"
    mv "$tmp" "$env_file"
  else
    echo "${key}=${value}" >> "$env_file"
  fi
}
if [[ -n "${RELEASE_ENV:-}" && -f "${RELEASE_ENV}" ]]; then
  echo "Применяю release env: $RELEASE_ENV"
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*# || -z "${line// }" ]] && continue
    set_var "${line%%=*}" "${line#*=}"
  done < "$RELEASE_ENV"
fi

# --- 2) снапшот текущих образов для отката ---
declare -A PREV_IMAGE
for svc in "${SERVICES[@]}"; do
  cid="$("${DC[@]}" ps -q "$svc" 2>/dev/null || true)"
  if [[ -n "$cid" ]]; then
    PREV_IMAGE[$svc]="$(docker inspect -f '{{.Image}}' "$cid" 2>/dev/null || true)"
  fi
done

# имя образа, которое compose присваивает сервису (для retag при откате)
image_ref_of() { "${DC[@]}" config --format json 2>/dev/null \
  | python3 -c "import sys,json;d=json.load(sys.stdin);print(d['services'].get('$1',{}).get('image',''))" 2>/dev/null || true; }

# --- 3) rebuild + 4) up ---
echo "Сборка образов (--pull)..."
"${DC[@]}" build --pull "${SERVICES[@]}"
echo "Перезапуск..."
"${DC[@]}" up -d "${SERVICES[@]}"

# --- 5) health-check home-node ---
HOME_PORT="$(grep -E '^HOME_PORT=' .env 2>/dev/null | cut -d= -f2)"; HOME_PORT="${HOME_PORT:-8001}"
HEALTH_URL="http://localhost:${HOME_PORT}/health"
echo "Health-check: $HEALTH_URL"
healthy=false
for i in $(seq 1 30); do
  if curl -fsS -m 3 "$HEALTH_URL" >/dev/null 2>&1; then healthy=true; break; fi
  sleep 2
done

if $healthy; then
  echo "✅ Обновление успешно, home-node здоров."
  exit 0
fi

# --- 6) авто-откат ---
echo "❌ Health-check не прошёл — откатываюсь на прежние образы." >&2
rolled=false
for svc in "${SERVICES[@]}"; do
  prev="${PREV_IMAGE[$svc]:-}"
  ref="$(image_ref_of "$svc")"
  if [[ -n "$prev" && -n "$ref" ]]; then
    docker tag "$prev" "$ref" 2>/dev/null && rolled=true
  fi
done
if $rolled; then
  "${DC[@]}" up -d --no-build "${SERVICES[@]}" || true
  echo "↩️  Откат выполнен на предыдущие образы. Проверьте логи: ${DC[*]} logs -f home-node" >&2
else
  echo "⚠️  Не удалось определить прежние образы для отката (первый запуск?)." >&2
  echo "    Проверьте логи: ${DC[*]} logs -f home-node" >&2
fi
exit 1
