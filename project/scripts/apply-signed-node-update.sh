#!/usr/bin/env bash
# Apply one TUF-verified OUO release. All inputs come from the root-only agent
# environment; the mobile/web owner client cannot supply commands or URLs.
set -euo pipefail

required=(
  OUO_UPDATE_METADATA_URL OUO_UPDATE_TARGETS_URL OUO_UPDATE_TARGET
  OUO_UPDATE_NODE_ID OUO_UPDATE_CURRENT_PROTOCOL
)
missing=()
for name in "${required[@]}"; do
  [[ -n "${!name:-}" ]] || missing+=("$name")
done
if ((${#missing[@]})); then
  printf 'Missing signed-update settings: %s\n' "${missing[*]}" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
UPDATE_ROOT="${OUO_UPDATE_ROOT:-/var/lib/ouo-update}"
METADATA_DIR="$UPDATE_ROOT/metadata"
TARGETS_DIR="$UPDATE_ROOT/targets"
RECEIPT="$UPDATE_ROOT/verified-receipt.json"
STATE="$UPDATE_ROOT/highest-release.json"
INSTALL_ROOT="${OUO_RELEASE_ROOT:-/opt/ouo-releases}"
HEALTH_URL="${OUO_UPDATE_HEALTH_URL:-http://127.0.0.1:8001/health}"

install -d -m 0700 "$UPDATE_ROOT" "$METADATA_DIR" "$TARGETS_DIR" "$INSTALL_ROOT"
[[ -f "$METADATA_DIR/root.json" ]] || {
  echo "Offline-provisioned $METADATA_DIR/root.json is required." >&2
  exit 2
}

python3 "$SCRIPT_DIR/prepare-secure-node-update.py" \
  --metadata-url "$OUO_UPDATE_METADATA_URL" \
  --targets-url "$OUO_UPDATE_TARGETS_URL" \
  --metadata-dir "$METADATA_DIR" \
  --targets-dir "$TARGETS_DIR" \
  --target "$OUO_UPDATE_TARGET" \
  --node-id "$OUO_UPDATE_NODE_ID" \
  --current-protocol "$OUO_UPDATE_CURRENT_PROTOCOL" \
  --state "$STATE" \
  --receipt "$RECEIPT"

python3 "$SCRIPT_DIR/install-verified-node-update.py" \
  --receipt "$RECEIPT" \
  --install-root "$INSTALL_ROOT" \
  --state "$STATE" \
  --restart-command-json '["docker","compose","up","-d","--remove-orphans"]' \
  --health-url "$HEALTH_URL"

chmod 0600 "$STATE" "$RECEIPT" 2>/dev/null || true
echo "Signed OUO update activated and health-checked."
