#!/usr/bin/env bash
###############################################################################
# up.sh — запустить пульт управления федерацией
###############################################################################
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

# ── Конфигурация ────────────────────────────────────────────────────────────
if [[ ! -f .env ]]; then
  cat <<'MSG'
✗ Нет файла .env

  Скопируйте образец и заполните:

    cp .env.example .env
    nano .env

MSG
  exit 1
fi

# ── Сертификаты ─────────────────────────────────────────────────────────────
MISSING=()
for f in certs/ca.crt certs/operator.crt certs/operator.key; do
  [[ -f "$f" ]] || MISSING+=("$f")
done

if [[ ${#MISSING[@]} -gt 0 ]]; then
  cat <<MSG
✗ Не хватает сертификатов:

$(printf '    %s\n' "${MISSING[@]}")

  На машине, где лежит CA, выпустите сертификат:

    cd project
    bash scripts/generate-operator-cert.sh $(hostname -s)

  Затем скопируйте сюда:

    config/mtls/ca.crt                        → certs/ca.crt
    config/mtls/operators/<имя>.crt           → certs/operator.crt
    config/mtls/operators/<имя>.key           → certs/operator.key

MSG
  exit 1
fi

# Приватный ключ не должен быть доступен другим пользователям машины
KEY_PERM="$(stat -f '%Lp' certs/operator.key 2>/dev/null || stat -c '%a' certs/operator.key)"
if [[ "$KEY_PERM" != "600" && "$KEY_PERM" != "400" ]]; then
  echo "⚠️  Права на certs/operator.key — $KEY_PERM. Исправляю на 600."
  chmod 600 certs/operator.key
fi

echo "=== Запускаю пульт оператора ==="
docker compose up -d --build

echo ""
echo "Проверяю связь с федерацией..."
sleep 3

STATUS="$(curl -s --max-time 5 http://127.0.0.1:9300/api/operator/status \
  -H "X-Admin-Panel-Secret: $(grep -E '^ADMIN_PANEL_SECRET=' .env | cut -d= -f2-)" \
  2>/dev/null || echo '')"

if [[ -n "$STATUS" ]] && echo "$STATUS" | grep -q '"ready": *true'; then
  echo "  ✓ сертификаты на месте"
else
  echo "  … пульт ещё поднимается, проверьте вручную через минуту"
fi

cat <<'MSG'

════════════════════════════════════════════════════════
  Пульт запущен
════════════════════════════════════════════════════════

  Открыть:  http://127.0.0.1:9300

  Браузер спросит секрет панели — тот, что в .env

  Логи:     docker compose logs -f
  Стоп:     ./down.sh

MSG
