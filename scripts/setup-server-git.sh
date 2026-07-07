#!/usr/bin/env bash
# Point this server's checkout at Gitea (flex/messenger) for git pull in node-update.
#
# Usage (on main or worker, as root):
#   GITEA_HOST=194.67.92.147 GITEA_OWNER=flex ./scripts/setup-server-git.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/deploy-common.sh
source "$SCRIPT_DIR/lib/deploy-common.sh"

GITEA_HOST="${GITEA_HOST:-194.67.92.147}"
GITEA_SSH_PORT="${GITEA_SSH_PORT:-2222}"
GITEA_OWNER="${GITEA_OWNER:-flex}"
GITEA_REPO="${GITEA_REPO:-messenger}"
GIT_BRANCH="${GIT_BRANCH:-main}"
SSH_KEY="${DEPLOY_SSH_KEY:-/root/.ssh/messenger_deploy}"

deploy_cd_root

mkdir -p "$(dirname "$SSH_KEY")"
if [[ ! -f "$SSH_KEY" ]]; then
  echo "Generating deploy key: $SSH_KEY"
  ssh-keygen -t ed25519 -f "$SSH_KEY" -N "" -C "messenger-deploy@$(hostname -s)"
fi
chmod 600 "$SSH_KEY"
chmod 644 "${SSH_KEY}.pub"

git config --global --add safe.directory "$DEPLOY_ROOT"

if ! git -C "$DEPLOY_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git -C "$DEPLOY_ROOT" init -b "$GIT_BRANCH"
fi

REMOTE_URL="ssh://git@${GITEA_HOST}:${GITEA_SSH_PORT}/${GITEA_OWNER}/${GITEA_REPO}.git"
if git -C "$DEPLOY_ROOT" remote get-url origin >/dev/null 2>&1; then
  git -C "$DEPLOY_ROOT" remote set-url origin "$REMOTE_URL"
else
  git -C "$DEPLOY_ROOT" remote add origin "$REMOTE_URL"
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

git -C "$DEPLOY_ROOT" remote set-url origin "ssh://messenger-gitea/${GITEA_OWNER}/${GITEA_REPO}.git"

mkdir -p "${DEPLOY_ROOT}/config/deploy"
PROFILE="${DEPLOY_ROOT}/config/deploy/node.profile"
touch "$PROFILE"
grep -v '^GIT_REMOTE=' "$PROFILE" 2>/dev/null | grep -v '^GIT_BRANCH=' > "${PROFILE}.tmp" || true
mv "${PROFILE}.tmp" "$PROFILE"
{
  echo "GIT_REMOTE=origin"
  echo "GIT_BRANCH=${GIT_BRANCH}"
} >> "$PROFILE"

echo
echo "=== Server git configured ==="
echo "Remote: ssh://messenger-gitea/${GITEA_OWNER}/${GITEA_REPO}.git"
echo
echo "Add this deploy key in Gitea (repo ${GITEA_OWNER}/${GITEA_REPO} → Settings → Deploy Keys):"
echo "---"
cat "${SSH_KEY}.pub"
echo "---"
echo
echo "Test after adding key:"
echo "  cd ${DEPLOY_ROOT} && git fetch origin ${GIT_BRANCH} && git merge --ff-only FETCH_HEAD"
