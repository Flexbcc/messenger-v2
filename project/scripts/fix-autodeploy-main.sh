#!/usr/bin/env bash
# Finish autodeploy on MAIN if enroll-worker stopped early.
# Run from laptop (uses laptop.env + passwordless SSH).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/laptop-env.sh
source "$SCRIPT_DIR/lib/laptop-env.sh"

load_laptop_env "$PROJECT_ROOT"
INSTALL_DIR="/opt/messenger/project"

[[ -n "${GITEA_PASSWORD:-}" ]] || {
  echo "Set GITEA_PASSWORD in config/deploy/laptop.env" >&2
  exit 1
}

RSYNC_OPTS=(-az --exclude data --exclude .env --exclude '__pycache__' --exclude '.git'
  --exclude 'client/messenger_app/build' --exclude 'client/messenger_app/.dart_tool')

echo "=== Sync scripts to MAIN ==="
laptop_rsync "${RSYNC_OPTS[@]}" "$PROJECT_ROOT/" "${MAIN_HOST}:${INSTALL_DIR}/"

echo "=== Complete MAIN autodeploy ==="
laptop_ssh "$MAIN_HOST" "cd ${INSTALL_DIR} && chmod +x deploy.sh scripts/*.sh scripts/lib/*.sh && \
  GITEA_PASSWORD='${GITEA_PASSWORD}' WORKER_HOST='${WORKER_HOST}' \
  ./scripts/setup-autodeploy.sh --role main"

echo "=== Test webhook + manual deploy ==="
laptop_ssh "$MAIN_HOST" "curl -sf http://127.0.0.1:9009/health && echo webhook-ok; \
  cd ${INSTALL_DIR} && ./deploy.sh"

echo "=== Done ==="
echo "Now: ./scripts/test-autodeploy.sh"
