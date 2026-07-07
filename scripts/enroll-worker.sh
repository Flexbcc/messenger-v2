#!/usr/bin/env bash
# Enroll a new WORKER node end-to-end (no manual Gitea/SSH steps).
#
# Run from laptop:
#   ./scripts/setup-laptop-ssh.sh          # once
#   cp config/deploy/laptop.env.example config/deploy/laptop.env  # set GITEA_PASSWORD
#   ./scripts/enroll-worker.sh --worker root@161.104.18.45 --worker-ip 161.104.18.45
set -euo pipefail

WORKER_HOST=""
WORKER_IP=""
WORKER_ROLE="${WORKER_ROLE:-full}"
INSTALL_DIR="/opt/messenger/project"
GITEA_OWNER="${GITEA_OWNER:-flex}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/laptop-env.sh
source "$SCRIPT_DIR/lib/laptop-env.sh"
load_laptop_env "$PROJECT_ROOT"

usage() {
  sed -n '2,8p' "$0"
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --main) MAIN_HOST="$2"; shift 2 ;;
    --main-ip) MAIN_IP="$2"; shift 2 ;;
    --worker) WORKER_HOST="$2"; shift 2 ;;
    --worker-ip) WORKER_IP="$2"; shift 2 ;;
    --worker-role) WORKER_ROLE="$2"; shift 2 ;;
    -h|--help) usage 0 ;;
    *) echo "Unknown: $1" >&2; usage 1 ;;
  esac
done

[[ -n "$WORKER_HOST" && -n "$WORKER_IP" ]] || {
  echo "Need --worker and --worker-ip" >&2
  usage 1
}
[[ -n "${GITEA_PASSWORD:-}" ]] || {
  echo "Set GITEA_PASSWORD in config/deploy/laptop.env" >&2
  exit 1
}

RSYNC_OPTS=(-az --delete --exclude data --exclude .env --exclude '__pycache__' --exclude '.git'
  --exclude 'client/messenger_app/build' --exclude 'client/messenger_app/.dart_tool')

echo "=== 1/6 Ensure MAIN autodeploy ==="
laptop_rsync "${RSYNC_OPTS[@]}" "$PROJECT_ROOT/" "${MAIN_HOST}:${INSTALL_DIR}/"
laptop_ssh "$MAIN_HOST" "cd ${INSTALL_DIR} && chmod +x deploy.sh scripts/*.sh scripts/lib/*.sh 2>/dev/null; \
  GITEA_PASSWORD='${GITEA_PASSWORD}' GITEA_OWNER='${GITEA_OWNER}' WORKER_HOST='${WORKER_HOST}' \
  ./scripts/setup-autodeploy.sh --role main"

echo "=== 2/6 Upload + bootstrap WORKER ==="
laptop_rsync "${RSYNC_OPTS[@]}" "$PROJECT_ROOT/" "${WORKER_HOST}:${INSTALL_DIR}/"
laptop_ssh "$WORKER_HOST" "cd ${INSTALL_DIR} && chmod +x deploy.sh scripts/*.sh scripts/lib/*.sh 2>/dev/null; \
  GITEA_PASSWORD='${GITEA_PASSWORD}' MAIN_IP='${MAIN_IP}' THIS_IP='${WORKER_IP}' WORKER_ROLE='${WORKER_ROLE}' \
  GITEA_OWNER='${GITEA_OWNER}' ./scripts/setup-autodeploy.sh --role worker"

echo "=== 3/6 SSH key exchange (main -> worker) ==="
ORCH_PUB=$(laptop_ssh "$MAIN_HOST" 'cat /root/.ssh/messenger_orchestrator.pub')
laptop_ssh "$WORKER_HOST" "mkdir -p /root/.ssh && chmod 700 /root/.ssh && grep -qF '${ORCH_PUB}' /root/.ssh/authorized_keys 2>/dev/null || echo '${ORCH_PUB}' >> /root/.ssh/authorized_keys"

echo "=== 4/6 Register deploy keys in Gitea (API) ==="
MAIN_DEPLOY_PUB=$(laptop_ssh "$MAIN_HOST" 'cat /root/.ssh/messenger_deploy.pub')
WORKER_DEPLOY_PUB=$(laptop_ssh "$WORKER_HOST" 'cat /root/.ssh/messenger_deploy.pub')
laptop_ssh "$MAIN_HOST" "cd ${INSTALL_DIR} && GITEA_PASSWORD='${GITEA_PASSWORD}' GITEA_OWNER='${GITEA_OWNER}' \
  ./scripts/register-gitea-deploy-keys.sh main '${MAIN_DEPLOY_PUB}' worker '${WORKER_DEPLOY_PUB}'"

echo "=== 5/6 Add worker to workers.list ==="
laptop_ssh "$MAIN_HOST" "cd ${INSTALL_DIR} && ./scripts/add-worker.sh '${WORKER_HOST}'"

echo "=== 6/6 First deploy ==="
laptop_ssh "$MAIN_HOST" "cd ${INSTALL_DIR} && ./deploy.sh"

echo
echo "=== Worker enrolled ==="
echo "Worker: ${WORKER_HOST}"
echo "Next: git push origin main"
