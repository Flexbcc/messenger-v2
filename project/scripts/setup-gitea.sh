#!/usr/bin/env bash
# Install Gitea + auto-deploy webhook on the MAIN server.
#
# Prerequisites: Docker, project at /opt/messenger/project (or run install-node.sh first).
#
# Usage (on server, as root):
#   cd /opt/messenger/project
#   sudo ./scripts/setup-gitea.sh
#
# Non-interactive:
#   PUBLIC_IP=1.2.3.4 GITEA_USER=admin GITEA_PASSWORD=secret \
#     DEPLOY_WEBHOOK_SECRET=whsec_xxx NONINTERACTIVE=1 \
#     sudo ./scripts/setup-gitea.sh
#
# After setup, from laptop:
#   git remote add origin ssh://git@MAIN_IP:2222/admin/messenger.git
#   git push -u origin main
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/deploy-common.sh
source "$SCRIPT_DIR/lib/deploy-common.sh"

GITEA_DIR="${GITEA_DIR:-/opt/gitea}"
GITEA_HTTP_PORT="${GITEA_HTTP_PORT:-3000}"
GITEA_SSH_PORT="${GITEA_SSH_PORT:-2222}"
GITEA_USER="${GITEA_USER:-admin}"
GITEA_REPO="${GITEA_REPO:-messenger}"
GIT_BRANCH="${GIT_BRANCH:-main}"
WEBHOOK_PORT="${DEPLOY_WEBHOOK_PORT:-9009}"

if [[ $EUID -ne 0 ]]; then
  echo "Run with sudo." >&2
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker required. Run: sudo ./scripts/install-node.sh --skip-firewall ..." >&2
  exit 1
fi

deploy_cd_root

PUBLIC_IP="${PUBLIC_IP:-}"
if [[ -z "$PUBLIC_IP" ]]; then
  PUBLIC_IP=$(curl -fsSL -4 ifconfig.me 2>/dev/null || curl -fsSL -4 icanhazip.com 2>/dev/null || true)
fi
if [[ -z "$PUBLIC_IP" && "${NONINTERACTIVE:-}" != "1" ]]; then
  read -rp "Public IP or domain of this server: " PUBLIC_IP
fi
[[ -n "$PUBLIC_IP" ]] || { echo "PUBLIC_IP required." >&2; exit 1; }

GITEA_DOMAIN="${GITEA_DOMAIN:-$PUBLIC_IP}"
GITEA_ROOT_URL="${GITEA_ROOT_URL:-http://${PUBLIC_IP}:${GITEA_HTTP_PORT}/}"

if [[ -z "${GITEA_PASSWORD:-}" ]]; then
  if [[ "${NONINTERACTIVE:-}" == "1" ]]; then
    GITEA_PASSWORD=$(python3 -c "import secrets; print(secrets.token_urlsafe(16))")
    echo "Generated GITEA_PASSWORD"
  else
    read -rsp "Gitea admin password for user '$GITEA_USER': " GITEA_PASSWORD
    echo
  fi
fi

if [[ -z "${DEPLOY_WEBHOOK_SECRET:-}" ]]; then
  DEPLOY_WEBHOOK_SECRET=$(python3 -c "import secrets; print(secrets.token_urlsafe(32))" 2>/dev/null || openssl rand -base64 32)
  echo "Generated DEPLOY_WEBHOOK_SECRET"
fi

mkdir -p "$GITEA_DIR"
ENV_FILE="$GITEA_DIR/.env"
cat > "$ENV_FILE" <<EOF
GITEA_DOMAIN=${GITEA_DOMAIN}
GITEA_ROOT_URL=${GITEA_ROOT_URL}
GITEA_SSH_DOMAIN=${PUBLIC_IP}
GITEA_HTTP_PORT=${GITEA_HTTP_PORT}
GITEA_SSH_PORT=${GITEA_SSH_PORT}
GITEA_INSTALL_LOCK=true
EOF

cp "$DEPLOY_ROOT/deploy/gitea/docker-compose.yml" "$GITEA_DIR/docker-compose.yml"
echo "Starting Gitea in $GITEA_DIR ..."
docker compose -f "$GITEA_DIR/docker-compose.yml" --env-file "$ENV_FILE" up -d

echo "Waiting for Gitea to become ready..."
for _ in $(seq 1 60); do
  if curl -sf "http://127.0.0.1:${GITEA_HTTP_PORT}/api/healthz" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

# First boot: create admin + repo via gitea CLI inside container.
echo "Ensuring Gitea user '$GITEA_USER' exists and password is synced..."
if ! docker exec gitea gitea admin user change-password \
  --username "$GITEA_USER" \
  --password "$GITEA_PASSWORD"; then
  docker exec gitea gitea admin user create \
    --username "$GITEA_USER" \
    --password "$GITEA_PASSWORD" \
    --email "${GITEA_USER}@localhost" \
    --admin
fi

docker exec -u git gitea gitea admin create-repo \
  --name "$GITEA_REPO" \
  --owner "$GITEA_USER" \
  --private 2>/dev/null || true

API="http://127.0.0.1:${GITEA_HTTP_PORT}/api/v1"
AUTH=(-u "${GITEA_USER}:${GITEA_PASSWORD}")
if ! curl -sf "${API}/repos/${GITEA_USER}/${GITEA_REPO}" "${AUTH[@]}" >/dev/null 2>&1; then
  echo "Creating repo via API..."
  curl -sf -X POST "${API}/user/repos" "${AUTH[@]}" \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"${GITEA_REPO}\",\"private\":true}" >/dev/null \
    || echo "WARN: create repo manually in Gitea UI" >&2
fi

# --- Deploy webhook systemd service ---
chmod +x "$DEPLOY_ROOT/deploy.sh" "$DEPLOY_ROOT/scripts/deploy-webhook.py"
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

# --- Wire working copy to Gitea ---
INTERNAL_GIT="http://127.0.0.1:${GITEA_HTTP_PORT}/${GITEA_USER}/${GITEA_REPO}.git"

# Git refuses to run in dirs owned by another uid (common after rsync + sudo).
git config --global --add safe.directory "$DEPLOY_ROOT"
chown -R root:root "$DEPLOY_ROOT" 2>/dev/null || true

if ! git -C "$DEPLOY_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git -C "$DEPLOY_ROOT" init -b "$GIT_BRANCH"
fi
git -C "$DEPLOY_ROOT" checkout -B "$GIT_BRANCH" 2>/dev/null || true

if git -C "$DEPLOY_ROOT" remote get-url origin >/dev/null 2>&1; then
  git -C "$DEPLOY_ROOT" remote set-url origin "$INTERNAL_GIT"
else
  git -C "$DEPLOY_ROOT" remote add origin "$INTERNAL_GIT"
fi

git -C "$DEPLOY_ROOT" config credential.helper store 2>/dev/null || true
CREDS_FILE="$HOME/.git-credentials"
if [[ ! -f "$CREDS_FILE" ]] || ! grep -q "127.0.0.1:${GITEA_HTTP_PORT}" "$CREDS_FILE" 2>/dev/null; then
  echo "http://${GITEA_USER}:${GITEA_PASSWORD}@127.0.0.1:${GITEA_HTTP_PORT}" >> "$CREDS_FILE"
  chmod 600 "$CREDS_FILE"
fi

# Initial push (may fail if repo already has content — ok).
git -C "$DEPLOY_ROOT" add -A 2>/dev/null || true
if git -C "$DEPLOY_ROOT" diff --cached --quiet 2>/dev/null; then
  :
else
  git -C "$DEPLOY_ROOT" -c user.email="${GITEA_USER}@localhost" -c user.name="deploy" \
    commit -m "initial deploy checkout" 2>/dev/null || true
fi
git -C "$DEPLOY_ROOT" push -u origin "$GIT_BRANCH" 2>/dev/null || \
  git -C "$DEPLOY_ROOT" pull origin "$GIT_BRANCH" --rebase 2>/dev/null || true

# --- Gitea webhook (push → deploy) ---
HOOK_URL="http://127.0.0.1:${WEBHOOK_PORT}/hook"
API="http://127.0.0.1:${GITEA_HTTP_PORT}/api/v1"
AUTH=(-u "${GITEA_USER}:${GITEA_PASSWORD}")

existing=$(curl -sf "${API}/repos/${GITEA_USER}/${GITEA_REPO}/hooks" "${AUTH[@]}" 2>/dev/null || echo "[]")
if ! echo "$existing" | grep -q "$HOOK_URL"; then
  if curl -sf -X POST "${API}/repos/${GITEA_USER}/${GITEA_REPO}/hooks" "${AUTH[@]}" \
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
)" >/dev/null; then
    echo "Gitea webhook installed → $HOOK_URL"
  else
    echo "WARN: could not create webhook (create repo in Gitea UI first?)" >&2
  fi
fi

# Update node.profile git settings
mkdir -p "$DEPLOY_ROOT/config/deploy"
PROFILE="$DEPLOY_ROOT/config/deploy/node.profile"
if [[ -f "$PROFILE" ]]; then
  grep -v '^GIT_REMOTE=' "$PROFILE" | grep -v '^GIT_BRANCH=' > "${PROFILE}.tmp" || true
  mv "${PROFILE}.tmp" "$PROFILE"
fi
{
  echo "GIT_REMOTE=origin"
  echo "GIT_BRANCH=${GIT_BRANCH}"
} >> "$PROFILE"

# Save secrets for operator (restricted)
SECRETS_FILE="$DEPLOY_ROOT/config/deploy/gitea.env"
cat > "$SECRETS_FILE" <<EOF
# Generated by setup-gitea.sh — keep private
GITEA_URL=${GITEA_ROOT_URL}
GITEA_USER=${GITEA_USER}
GITEA_PASSWORD=${GITEA_PASSWORD}
GITEA_SSH=ssh://git@${PUBLIC_IP}:${GITEA_SSH_PORT}/${GITEA_USER}/${GITEA_REPO}.git
DEPLOY_WEBHOOK_SECRET=${DEPLOY_WEBHOOK_SECRET}
EOF
chmod 600 "$SECRETS_FILE"

echo
echo "============================================"
echo " Gitea + auto-deploy ready"
echo "============================================"
echo "Gitea UI:     ${GITEA_ROOT_URL}"
echo "Login:        ${GITEA_USER} / (see ${SECRETS_FILE})"
echo "Git SSH:      ssh://git@${PUBLIC_IP}:${GITEA_SSH_PORT}/${GITEA_USER}/${GITEA_REPO}.git"
echo "Deploy log:   /var/log/messenger-deploy.log"
echo
echo "From your laptop:"
echo "  cd project"
echo "  git init && git add . && git commit -m 'init'"
echo "  git remote add origin ssh://git@${PUBLIC_IP}:${GITEA_SSH_PORT}/${GITEA_USER}/${GITEA_REPO}.git"
echo "  git push -u origin ${GIT_BRANCH}"
echo
echo "Or one command:"
echo "  ./scripts/push-deploy.sh --host git@${PUBLIC_IP} --port ${GITEA_SSH_PORT}"
echo
echo "Manual deploy on server:"
echo "  cd ${DEPLOY_ROOT} && ./deploy.sh"
echo "============================================"
