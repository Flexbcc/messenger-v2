#!/usr/bin/env bash
# Regenerate releases/clients/manifest.json version fields from pubspec.yaml.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="$ROOT/releases/clients/manifest.json"
MSG_PUB="$ROOT/client/messenger_app/pubspec.yaml"
STOR_PUB="$ROOT/../storage-app/app/pubspec.yaml"
if [[ ! -f "$STOR_PUB" ]]; then
  STOR_PUB="$(cd "$ROOT/.." && pwd)/storage-app/app/pubspec.yaml"
fi
if [[ ! -f "$STOR_PUB" ]]; then
  echo "storage pubspec not found (optional)" >&2
  STOR_VER="0.1.0"; STOR_BUILD="1"
fi

read_pubspec() {
  local file="$1"
  local line
  line="$(grep '^version:' "$file" | head -1 | awk '{print $2}')"
  local ver="${line%%+*}"
  local build="${line#*+}"
  [[ "$build" == "$line" ]] && build="1"
  echo "$ver $build"
}

read -r MSG_VER MSG_BUILD <<< "$(read_pubspec "$MSG_PUB")"
if [[ -f "$STOR_PUB" ]]; then
  read -r STOR_VER STOR_BUILD <<< "$(read_pubspec "$STOR_PUB")"
else
  STOR_VER="${STOR_VER:-0.1.0}"; STOR_BUILD="${STOR_BUILD:-1}"
fi
STAMP="${BUILD_STAMP:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
LANDING="${LANDING_URL:-http://194.67.92.147:7357}"
NOTES="${RELEASE_NOTES:-}"

python3 - "$MANIFEST" "$MSG_VER" "$MSG_BUILD" "$STOR_VER" "$STOR_BUILD" "$STAMP" "$LANDING" "$NOTES" <<'PY'
import json, sys
from pathlib import Path

path, msg_v, msg_b, stor_v, stor_b, stamp, landing, notes = sys.argv[1:9]
path = Path(path)
data = json.loads(path.read_text()) if path.exists() else {"schema": 1, "channel": "beta", "products": {}}

data["updated_at"] = stamp
data["landing_url"] = landing
data.setdefault("channel", "beta")

def bump_product(key, ver, build, default_notes):
    p = data["products"].setdefault(key, {"platforms": {}})
    p["version"] = ver
    p["build"] = int(build)
    p.setdefault("channel", "beta")
    if notes:
        p["release_notes"] = notes
    elif "release_notes" not in p:
        p["release_notes"] = default_notes
    for plat, cfg in p.get("platforms", {}).items():
        cfg["version"] = ver
        cfg["build"] = int(build)

bump_product(
    "messenger", msg_v, msg_b,
    "E2EE-чаты, звонки, private mode, каталог настроек.",
)
bump_product(
    "storage", stor_v, stor_b,
    "Личное хранилище на ПК для медиа мессенджера.",
)

path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
print(f"manifest → {path} (messenger {msg_v}+{msg_b}, storage {stor_v}+{stor_b})")
PY

# Mirror for landing static host
mkdir -p "$ROOT/landing/releases/clients"
cp "$MANIFEST" "$ROOT/landing/releases/clients/manifest.json"
