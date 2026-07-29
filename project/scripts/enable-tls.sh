#!/usr/bin/env bash
# Включить TLS между нодами (nginx reverse proxy + сертификаты).
# Использование: bash scripts/enable-tls.sh [--force]
#
# Что делает:
#   1. Генерирует CA + сертификаты (если нет или --force)
#   2. Поднимает nginx-tls сервис (profile=tls)
#   3. Проверяет, что TLS-порты отвечают
#
# После включения ноды доступны по HTTPS на портах 8101-8105.
# Чтобы federation тоже ходила через TLS — обновите NODE_*_PUBLIC_URL в .env
# на https://... и перезапустите ноды.

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1

# ── 1. Сертификаты ──────────────────────────────────────────────────────────
if [[ ! -f config/mtls/gateway.crt ]] || [[ "$FORCE" == "1" ]]; then
    echo "→ Генерация сертификатов..."
    FORCE=$FORCE bash scripts/generate-mtls-certs.sh
else
    echo "✓ Сертификаты уже есть (config/mtls/gateway.crt)"
fi

# ── 2. Поднять nginx-tls ─────────────────────────────────────────────────────
echo "→ Запуск nginx-tls..."
docker compose --profile tls up -d nginx-tls

# ── 3. Проверка ──────────────────────────────────────────────────────────────
echo "→ Проверка TLS-портов (ждём 3с)..."
sleep 3

PORTS=(8101 8102 8103 8104 8105)
NAMES=(home storage discovery media relay)
ALL_OK=true

for i in "${!PORTS[@]}"; do
    PORT="${PORTS[$i]}"
    NAME="${NAMES[$i]}"
    if curl -sk --max-time 3 "https://localhost:${PORT}/health" -o /dev/null; then
        echo "  ✓ ${NAME}-node TLS :${PORT}"
    else
        echo "  ✗ ${NAME}-node TLS :${PORT} — не ответил"
        ALL_OK=false
    fi
done

echo ""
if [[ "$ALL_OK" == "true" ]]; then
    echo "✓ TLS активен. Все ноды отвечают по HTTPS."
    echo ""
    echo "Следующий шаг — обновить .env для federation через TLS:"
    echo "  HOME_NODE_PUBLIC_URL=https://<IP>:8101"
    echo "  RELAY_NODE_PUBLIC_URL=https://<IP>:8105"
    echo "  ... и т.д., затем docker compose up -d"
else
    echo "⚠ Некоторые ноды не ответили. Проверьте:"
    echo "  docker compose --profile tls logs nginx-tls"
fi
