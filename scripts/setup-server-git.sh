#!/usr/bin/env bash
# Point this server's checkout at Gitea (flex/messenger) for git pull in node-update.
#
# Usage (on main or worker, as root):
#   GITEA_PASSWORD=secret GITEA_HOST=194.67.92.147 ./scripts/setup-server-git.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/deploy-common.sh
source "$SCRIPT_DIR/lib/deploy-common.sh"
# shellcheck source=lib/ssh-keys.sh
source "$SCRIPT_DIR/lib/ssh-keys.sh"
# shellcheck source=lib/gitea-api.sh
source "$SCRIPT_DIR/lib/gitea-api.sh"

GITEA_HOST="${GITEA_HOST:-194.67.92.147}"
GITEA_SSH_PORT="${GITEA_SSH_PORT:-2222}"
GITEA_OWNER="${GITEA_OWNER:-flex}"
GITEA_REPO="${GITEA_REPO:-messenger}"
GIT_BRANCH="${GIT_BRANCH:-main}"
SSH_KEY="${DEPLOY_SSH_KEY:-/root/.ssh/messenger_deploy}"
KEY_TITLE="${DEPLOY_KEY_TITLE:-deploy-$(hostname -s)}"

deploy_cd_root
ensure_deploy_git_key "$SSH_KEY"

git config --global --add safe.directory "$DEPLOY_ROOT"

if ! git -C "$DEPLOY_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git -C "$DEPLOY_ROOT" init -b "$GIT_BRANCH"
fi

mkdir -p /root/.ssh
SSH_CONFIG=/root/.ssh/config
if ! grep -q "Host messenger-gitea" "$SSH_CONFIG" 2>/dev/null; then
  cat >> "$SSH_CONFIG" <<EOF

Host messenger-gitea
  HostName ${GITEA_HOST}
  Port ${GITEA_SSH_PORT}
  User git
  IdentityFile ${SSH_KEY}
  IdentitiesOnly yes
EOF
  chmod 600 "$SSH_CONFIG"
fi

REMOTE_URL="ssh://messenger-gitea/${GITEA_OWNER}/${GITEA_REPO}.git"
if git -C "$DEPLOY_ROOT" remote get-url origin >/dev/null 2>&1; then
  git -C "$DEPLOY_ROOT" remote set-url origin "$REMOTE_URL"
else
  git -C "$DEPLOY_ROOT" remote add origin "$REMOTE_URL"
fi

mkdir -p "${DEPLOY_ROOT}/config/deploy"
PROFILE="${DEPLOY_ROOT}/config/deploy/node.profile"
touch "$PROFILE"
grep -v '^GIT_REMOTE=' "$PROFILE" 2>/dev/null | grep -v '^GIT_BRANCH=' > "${PROFILE}.tmp" || true
mv "${PROFILE}.tmp" "$PROFILE"
{
  echo "GIT_REMOTE=origin"
  echo "GIT_BRANCH=${GIT_BRANCH}"
} >> "$PROFILE"

if gitea_load_credentials 2>/dev/null; then
  gitea_register_deploy_key "$KEY_TITLE" "$(cat "${SSH_KEY}.pub")" true || true
else
  echo "WARN: GITEA_PASSWORD not set — deploy key not registered via API." >&2
fi

echo "Server git ready: $REMOTE_URL"
