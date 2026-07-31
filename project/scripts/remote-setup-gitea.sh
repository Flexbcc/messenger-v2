#!/usr/bin/env bash
# Upload latest project + run setup-gitea.sh on main server (interactive SSH password OK).
#
# Usage:
#   ./scripts/remote-setup-gitea.sh
#   ./scripts/remote-setup-gitea.sh --host root@194.67.92.147
set -euo pipefail

HOST="${HOST:-root@194.67.92.147}"
PUBLIC_IP="${PUBLIC_IP:-194.67.92.147}"
INSTALL_DIR="/opt/messenger/project"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) HOST="$2"; shift 2 ;;
    --ip) PUBLIC_IP="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,6p' "$0"
      exit 0
      ;;
    *) echo "Unknown: $1" >&2; exit 1 ;;
  esac
done

echo "=== Upload project -> ${HOST}:${INSTALL_DIR} ==="
ssh "$HOST" "mkdir -p $(dirname "$INSTALL_DIR")"
rsync -az --delete \
  --exclude data --exclude .env --exclude '__pycache__' --exclude '.git' \
  --exclude 'client/messenger_app/build' --exclude 'client/messenger_app/.dart_tool' \
  "$PROJECT_ROOT/" "${HOST}:${INSTALL_DIR}/"

echo
echo "=== Install Gitea + deploy webhook on server ==="
echo "(enter root password if asked)"
ssh -t "$HOST" "cd ${INSTALL_DIR} && chmod +x deploy.sh scripts/*.sh scripts/deploy-webhook.py && PUBLIC_IP=${PUBLIC_IP} NONINTERACTIVE=1 ./scripts/setup-gitea.sh"

echo
echo "=== Done ==="
echo "Log:  ssh ${HOST} 'tail -f /var/log/messenger-deploy.log'"
echo "Push: ./scripts/push-deploy.sh --host ${PUBLIC_IP}"
