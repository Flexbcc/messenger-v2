#!/usr/bin/env bash
# Apply S3 storage profile template → config/storage.json
#
# Usage:
#   cp config/storage.examples/storage.secrets.env.example config/storage.secrets.env
#   # edit secrets
#   ./scripts/apply-storage-profile.sh hybrid-backup.yandex
#   ./scripts/apply-storage-profile.sh --list
#   ./scripts/apply-storage-profile.sh hybrid-backup.yandex --reload
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
EXAMPLES="${PROJECT_ROOT}/config/storage.examples"
TARGET="${PROJECT_ROOT}/config/storage.json"
SECRETS="${STORAGE_SECRETS_FILE:-${PROJECT_ROOT}/config/storage.secrets.env}"
RELOAD=""

usage() {
  echo "Usage: $0 <profile-name> [--reload]"
  echo "       $0 --list"
  echo
  echo "Profiles in ${EXAMPLES}/"
  exit "${1:-0}"
}

list_profiles() {
  python3 - <<'PY' "${EXAMPLES}"
import json
from pathlib import Path
import sys
root = Path(sys.argv[1])
for f in sorted(root.glob("*.json")):
    p = json.loads(f.read_text(encoding="utf-8"))
    name = p.get("_profile", f.stem)
    print(f"  {name}")
    if p.get("_description"):
        print(f"      {p['_description']}")
PY
}

substitute() {
  local src="$1" dst="$2"
  python3 - "$src" "$dst" "$SECRETS" <<'PY'
import json, os, re, sys
from pathlib import Path

src, dst, secrets_path = sys.argv[1], sys.argv[2], sys.argv[3]
text = Path(src).read_text(encoding="utf-8")

if Path(secrets_path).is_file():
    for line in Path(secrets_path).read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, _, v = line.partition("=")
        os.environ.setdefault(k.strip(), v.strip())

def repl(m):
    key = m.group(1)
    env_key = key.replace("__", "").strip("_")
    # __S3_REGION__ -> S3_REGION, __R2_ACCOUNT_ID__ -> R2_ACCOUNT_ID
    mapping = {
        "S3_REGION": "S3_REGION",
        "S3_BUCKET": "S3_BUCKET",
        "S3_ACCESS_KEY": "S3_ACCESS_KEY",
        "S3_SECRET_KEY": "S3_SECRET_KEY",
        "S3_ENDPOINT": "S3_ENDPOINT",
        "R2_ACCOUNT_ID": "R2_ACCOUNT_ID",
    }
    env = mapping.get(env_key, env_key)
    val = os.environ.get(env, m.group(0))
    return val

text = re.sub(r"__([A-Z0-9_]+)__", repl, text)
data = json.loads(text)
data.pop("_profile", None)
data.pop("_description", None)
Path(dst).write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
print(f"Wrote {dst}")
PY
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --list|-l) list_profiles; exit 0 ;;
    --reload) RELOAD=1; shift ;;
    -h|--help) usage 0 ;;
    *) break ;;
  esac
done

PROFILE="${1:-}"
[[ -n "$PROFILE" ]] || usage 1

SRC="${EXAMPLES}/${PROFILE}.json"
[[ -f "$SRC" ]] || SRC="${EXAMPLES}/${PROFILE}"
[[ -f "$SRC" ]] || { echo "Profile not found: $PROFILE" >&2; list_profiles; exit 1; }

if [[ ! -f "$SECRETS" ]]; then
  echo "WARN: $SECRETS missing — placeholders may remain in storage.json" >&2
  echo "      cp config/storage.examples/storage.secrets.env.example config/storage.secrets.env" >&2
fi

substitute "$SRC" "$TARGET"

if [[ -n "$RELOAD" ]]; then
  cd "$PROJECT_ROOT"
  if docker compose ps media-node 2>/dev/null | grep -q Up; then
  docker compose exec -T media-node python3 -c "from app.config_loader import reload_settings; reload_settings(); print('media-node: storage.json reloaded')"
  else
    echo "media-node not running — restart: docker compose up -d media-node"
  fi
fi

echo "Done. Test backup: docker compose exec media-node curl -s -X POST http://localhost:8004/admin/backup"
