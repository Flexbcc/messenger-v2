#!/usr/bin/env bash
# Register Gitea push webhook → local deploy webhook (main server only).
#
# Usage:
#   GITEA_USER=flex GITEA_PASSWORD=secret ./scripts/setup-gitea-webhook.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/deploy-common.sh
source "$SCRIPT_DIR/lib/deploy-common.sh"

GITEA_HTTP_PORT="${GITEA_HTTP_PORT:-3000}"
GITEA_USER="${GITEA_USER:-flex}"
GITEA_REPO="${GITEA_REPO:-messenger}"
GIT_BRANCH="${GIT_BRANCH:-main}"
WEBHOOK_PORT="${DEPLOY_WEBHOOK_PORT:-9009}"
SECRETS_FILE="${DEPLOY_ROOT}/config/deploy/gitea.env"

deploy_cd_root

if [[ -z "${GITEA_PASSWORD:-}" && -f "$SECRETS_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$SECRETS_FILE"
fi
[[ -n "${GITEA_PASSWORD:-}" ]] || { echo "Set GITEA_PASSWORD (flex account password)." >&2; exit 1; }

if [[ -z "${DEPLOY_WEBHOOK_SECRET:-}" ]]; then
  if [[ -f "$SECRETS_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$SECRETS_FILE"
  fi
fi
if [[ -z "${DEPLOY_WEBHOOK_SECRET:-}" ]]; then
  DEPLOY_WEBHOOK_SECRET=$(python3 -c "import secrets; print(secrets.token_urlsafe(32))")
fi

chmod +x "${DEPLOY_ROOT}/deploy.sh" "${DEPLOY_ROOT}/scripts/deploy-webhook.py"
touch /var/log/messenger-deploy.log

UNIT=/etc/systemd/system/messenger-deploy-webhook.service
cat > "$UNIT" <<EOF
[Unit]
Description=Messenger Gitea deploy webhook
After=network.target docker.service

[Service]
Type=simple
User=root
WorkingDirectory=${DEPLOY_ROOT}
Environment=DEPLOY_ROOT=${DEPLOY_ROOT}
Environment=GIT_BRANCH=${GIT_BRANCH}
Environment=DEPLOY_WEBHOOK_PORT=${WEBHOOK_PORT}
Environment=DEPLOY_WEBHOOK_SECRET=${DEPLOY_WEBHOOK_SECRET}
Environment=DEPLOY_LOG=/var/log/messenger-deploy.log
ExecStart=/usr/bin/python3 ${DEPLOY_ROOT}/scripts/deploy-webhook.py
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable messenger-deploy-webhook
systemctl restart messenger-deploy-webhook

HOOK_URL="http://127.0.0.1:${WEBHOOK_PORT}/hook"
API="http://127.0.0.1:${GITEA_HTTP_PORT}/api/v1"
AUTH=(-u "${GITEA_USER}:${GITEA_PASSWORD}")

existing=$(curl -sf "${API}/repos/${GITEA_USER}/${GITEA_REPO}/hooks" "${AUTH[@]}" 2>/dev/null || echo "[]")
hook_ids=$(echo "$existing" | python3 -c "
import json,sys
data=json.load(sys.stdin)
for h in data:
    cfg=h.get('config') or {}
    if cfg.get('url')=='${HOOK_URL}':
        print(h.get('id',''))
" 2>/dev/null || true)

if [[ -z "$hook_ids" ]]; then
  curl -sf -X POST "${API}/repos/${GITEA_USER}/${GITEA_REPO}/hooks" "${AUTH[@]}" \
    -H "Content-Type: application/json" \
    -d "$(python3 - <<PY
import json
print(json.dumps({
    "type": "gitea",
    "config": {
        "url": "${HOOK_URL}",
        "content_type": "json",
        "secret": "${DEPLOY_WEBHOOK_SECRET}",
    },
    "events": ["push"],
    "active": True,
}))
PY
)" >/dev/null
  echo "Webhook created: ${HOOK_URL}"
else
  echo "Webhook already exists for ${GITEA_USER}/${GITEA_REPO}"
fi

mkdir -p "${DEPLOY_ROOT}/config/deploy"
cat > "$SECRETS_FILE" <<EOF
# Gitea deploy — keep private
GITEA_URL=http://127.0.0.1:${GITEA_HTTP_PORT}/
GITEA_USER=${GITEA_USER}
GITEA_PASSWORD=${GITEA_PASSWORD}
GITEA_SSH=ssh://git@194.67.92.147:2222/${GITEA_USER}/${GITEA_REPO}.git
DEPLOY_WEBHOOK_SECRET=${DEPLOY_WEBHOOK_SECRET}
EOF
chmod 600 "$SECRETS_FILE"

echo "Webhook service: $(systemctl is-active messenger-deploy-webhook)"
echo "Test: curl -s http://127.0.0.1:${WEBHOOK_PORT}/health"
