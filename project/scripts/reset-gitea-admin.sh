#!/usr/bin/env bash
# Sync Gitea admin password with config/deploy/gitea.env (or set a new one).
#
# Usage on server:
#   sudo ./scripts/reset-gitea-admin.sh
#   sudo GITEA_PASSWORD='my-new-pass' ./scripts/reset-gitea-admin.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/deploy-common.sh
source "$SCRIPT_DIR/lib/deploy-common.sh"

GITEA_USER="${GITEA_USER:-admin}"
SECRETS_FILE="${DEPLOY_ROOT}/config/deploy/gitea.env"

if [[ $EUID -ne 0 ]]; then
  echo "Run with sudo." >&2
  exit 1
fi

deploy_cd_root

if [[ -z "${GITEA_PASSWORD:-}" ]]; then
  if [[ -f "$SECRETS_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$SECRETS_FILE"
  fi
fi

if [[ -z "${GITEA_PASSWORD:-}" ]]; then
  GITEA_PASSWORD=$(python3 -c "import secrets; print(secrets.token_urlsafe(16))")
fi

if ! docker ps --format '{{.Names}}' | grep -qx gitea; then
  echo "Gitea container 'gitea' is not running." >&2
  exit 1
fi

echo "Ensuring admin user '$GITEA_USER' password is set..."
if ! docker exec gitea gitea admin user change-password \
  --username "$GITEA_USER" \
  --password "$GITEA_PASSWORD"; then
  echo "User '$GITEA_USER' not found, creating it..."
  docker exec gitea gitea admin user create \
    --username "$GITEA_USER" \
    --password "$GITEA_PASSWORD" \
    --email "${GITEA_USER}@localhost" \
    --admin
fi

# Ensure repo exists (API — works even when CLI differs between Gitea versions).
GITEA_HTTP_PORT="${GITEA_HTTP_PORT:-3000}"
GITEA_REPO="${GITEA_REPO:-messenger}"
API="http://127.0.0.1:${GITEA_HTTP_PORT}/api/v1"
AUTH=(-u "${GITEA_USER}:${GITEA_PASSWORD}")

if ! curl -sf "${API}/repos/${GITEA_USER}/${GITEA_REPO}" "${AUTH[@]}" >/dev/null 2>&1; then
  echo "Creating repo ${GITEA_USER}/${GITEA_REPO}..."
  curl -sf -X POST "${API}/user/repos" "${AUTH[@]}" \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"${GITEA_REPO}\",\"private\":true}" >/dev/null
fi

mkdir -p "$(dirname "$SECRETS_FILE")"
if [[ -f "$SECRETS_FILE" ]]; then
  if grep -q '^GITEA_PASSWORD=' "$SECRETS_FILE"; then
    tmp=$(mktemp)
    awk -F= -v p="$GITEA_PASSWORD" 'BEGIN{OFS="="} $1=="GITEA_PASSWORD"{print "GITEA_PASSWORD",p; next} {print}' \
      "$SECRETS_FILE" > "$tmp"
    mv "$tmp" "$SECRETS_FILE"
  else
    echo "GITEA_PASSWORD=${GITEA_PASSWORD}" >> "$SECRETS_FILE"
  fi
else
  PUBLIC_IP="${PUBLIC_IP:-194.67.92.147}"
  GITEA_SSH_PORT="${GITEA_SSH_PORT:-2222}"
  cat > "$SECRETS_FILE" <<EOF
GITEA_URL=http://${PUBLIC_IP}:${GITEA_HTTP_PORT}/
GITEA_USER=${GITEA_USER}
GITEA_PASSWORD=${GITEA_PASSWORD}
GITEA_SSH=ssh://git@${PUBLIC_IP}:${GITEA_SSH_PORT}/${GITEA_USER}/${GITEA_REPO}.git
EOF
fi
chmod 600 "$SECRETS_FILE"

echo
echo "Gitea login: ${GITEA_USER} / ${GITEA_PASSWORD}"
echo "Saved to:    ${SECRETS_FILE}"
echo "UI:          http://127.0.0.1:${GITEA_HTTP_PORT}/ (or your public IP)"
