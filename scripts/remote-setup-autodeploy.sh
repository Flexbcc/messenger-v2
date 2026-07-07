#!/usr/bin/env bash
# Upload scripts + configure autodeploy on MAIN and WORKER from laptop.
#
# Usage:
#   GITEA_PASSWORD='flex_password' ./scripts/remote-setup-autodeploy.sh
set -euo pipefail

MAIN_HOST="${MAIN_HOST:-root@194.67.92.147}"
WORKER_HOST="${WORKER_HOST:-root@161.104.18.45}"
MAIN_IP="${MAIN_IP:-194.67.92.147}"
WORKER_IP="${WORKER_IP:-161.104.18.45}"
INSTALL_DIR="/opt/messenger/project"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

[[ -n "${GITEA_PASSWORD:-}" ]] || {
  echo "Set GITEA_PASSWORD (password for Gitea user flex)." >&2
  exit 1
}

echo "=== Upload -> MAIN ==="
rsync -az --delete \
  --exclude data --exclude .env --exclude '__pycache__' --exclude '.git' \
  --exclude 'client/messenger_app/build' --exclude 'client/messenger_app/.dart_tool' \
  "$PROJECT_ROOT/" "${MAIN_HOST}:${INSTALL_DIR}/"

echo "=== Setup MAIN autodeploy ==="
ssh -t "$MAIN_HOST" "cd ${INSTALL_DIR} && chmod +x deploy.sh scripts/*.sh && \
  GITEA_PASSWORD='${GITEA_PASSWORD}' WORKER_HOST='${WORKER_HOST}' ./scripts/setup-autodeploy.sh --role main"

echo
echo "=== Upload -> WORKER ==="
rsync -az --delete \
  --exclude data --exclude .env --exclude '__pycache__' --exclude '.git' \
  --exclude 'client/messenger_app/build' --exclude 'client/messenger_app/.dart_tool' \
  "$PROJECT_ROOT/" "${WORKER_HOST}:${INSTALL_DIR}/"

echo "=== Setup WORKER autodeploy ==="
ssh -t "$WORKER_HOST" "cd ${INSTALL_DIR} && chmod +x deploy.sh scripts/*.sh && \
  MAIN_IP='${MAIN_IP}' THIS_IP='${WORKER_IP}' ./scripts/setup-autodeploy.sh --role worker"

echo
echo "=== Next manual steps (one time) ==="
echo "1) In Gitea flex/messenger → Settings → Deploy Keys:"
echo "   Add BOTH deploy public keys printed on main and worker:"
echo "   ssh ${MAIN_HOST} 'cat /root/.ssh/messenger_deploy.pub'"
echo "   ssh ${WORKER_HOST} 'cat /root/.ssh/messenger_deploy.pub'"
echo
echo "2) Passwordless SSH main -> worker:"
echo "   ssh ${MAIN_HOST} 'ssh-copy-id ${WORKER_HOST}'"
echo
echo "3) Test:"
echo "   ./scripts/test-autodeploy.sh --host ${MAIN_HOST} --worker ${WORKER_HOST}"
