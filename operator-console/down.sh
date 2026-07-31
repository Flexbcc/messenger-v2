#!/usr/bin/env bash
# down.sh — остановить пульт
set -euo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
docker compose down
echo "✓ Пульт остановлен. Сертификаты и .env на месте."
