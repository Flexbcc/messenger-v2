#!/bin/bash
# Горячий бэкап SQLite-баз всех нод client-node
# Запускать через cron: 0 3 * * * /path/to/client-node/scripts/backup.sh
set -euo pipefail

GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${GREEN}[✓]${NC} $*"; }
error() { echo -e "${RED}[✗]${NC} $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"

BACKUP_DIR="${ROOT}/data/backups"
KEEP_DAYS="${BACKUP_KEEP_DAYS:-7}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

mkdir -p "$BACKUP_DIR"

backup_db() {
    local name="$1" src="$2"
    local dst="${BACKUP_DIR}/${name}_${TIMESTAMP}.db"
    if [ -f "$src" ]; then
        sqlite3 "$src" ".backup '${dst}'" && info "Бэкап: $name → $(basename "$dst")"
    else
        error "$name: файл не найден ($src)"
    fi
}

echo ""
echo "── backup $(date '+%Y-%m-%d %H:%M:%S') ──"
echo ""

backup_db "home"     "${ROOT}/data/home/home.db"
backup_db "storage"  "${ROOT}/data/storage/storage.db"
backup_db "media"    "${ROOT}/data/media-meta/media.db"

# Удаляем старые бэкапы
find "$BACKUP_DIR" -name "*.db" -mtime "+${KEEP_DAYS}" -delete
info "Старые бэкапы (>${KEEP_DAYS} дней) удалены"

echo ""
info "Бэкап завершён. Файлы: ${BACKUP_DIR}"
