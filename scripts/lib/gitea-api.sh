# Gitea API helpers. Source from other scripts.
set -euo pipefail

gitea_load_credentials() {
  local secrets="${1:-${DEPLOY_ROOT}/config/deploy/gitea.env}"
  GITEA_HTTP_PORT="${GITEA_HTTP_PORT:-3000}"
  GITEA_USER="${GITEA_USER:-flex}"
  GITEA_REPO="${GITEA_REPO:-messenger}"
  GITEA_API="http://127.0.0.1:${GITEA_HTTP_PORT}/api/v1"

  if [[ -z "${GITEA_PASSWORD:-}" && -f "$secrets" ]]; then
    # shellcheck disable=SC1090
    source "$secrets"
  fi
  [[ -n "${GITEA_PASSWORD:-}" ]] || return 1
  GITEA_AUTH=(-u "${GITEA_USER}:${GITEA_PASSWORD}")
  return 0
}

gitea_deploy_key_exists() {
  local title="$1"
  local keys
  keys=$(curl -sf "${GITEA_API}/repos/${GITEA_USER}/${GITEA_REPO}/keys" "${GITEA_AUTH[@]}" 2>/dev/null || echo "[]")
  echo "$keys" | python3 -c "
import json,sys
title=sys.argv[1]
for item in json.load(sys.stdin):
    if item.get('title')==title:
        print('yes')
        break
" "$title" 2>/dev/null | grep -q yes
}

gitea_register_deploy_key() {
  local title="$1"
  local pubkey="$2"
  local read_only="${3:-true}"

  gitea_load_credentials || {
    echo "WARN: Gitea credentials missing — cannot register deploy key '$title'" >&2
    return 1
  }

  if gitea_deploy_key_exists "$title"; then
    echo "Deploy key already registered: $title"
    return 0
  fi

  curl -sf -X POST "${GITEA_API}/repos/${GITEA_USER}/${GITEA_REPO}/keys" "${GITEA_AUTH[@]}" \
    -H "Content-Type: application/json" \
    -d "$(python3 - "$title" "$pubkey" "$read_only" <<'PY'
import json, sys
title, key, ro = sys.argv[1], sys.argv[2], sys.argv[3]
print(json.dumps({
    "title": title,
    "key": key.strip(),
    "read_only": ro.lower() in ("1", "true", "yes"),
}))
PY
)" >/dev/null
  echo "Registered Gitea deploy key: $title"
}
