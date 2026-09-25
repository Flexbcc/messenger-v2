#!/usr/bin/env bash
# Deploy from your laptop to a VPS over SSH (no GitHub required).
#
# Usage:
#   # Main server (better VPS):
#   ./scripts/deploy-from-laptop.sh --host root@MAIN_IP --role main --ip MAIN_IP
#
#   # Worker server (simpler VPS):
#   ./scripts/deploy-from-laptop.sh --host root@WORKER_IP --role worker \
#     --ip WORKER_IP --main-ip MAIN_IP
#
# Requires: ssh, rsync (or scp), passwordless or interactive SSH to server.
set -euo pipefail

HOST=""
ROLE=""
THIS_IP=""
MAIN_IP=""
WORKER_ROLE="full"
SSH_USER=""
INSTALL_DIR="/opt/messenger/project"
DRY_RUN=""

usage() {
  sed -n '2,12p' "$0"
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) HOST="$2"; shift 2 ;;
    --role) ROLE="$2"; shift 2 ;;
    --ip) THIS_IP="$2"; shift 2 ;;
    --main-ip) MAIN_IP="$2"; shift 2 ;;
    --worker-role) WORKER_ROLE="$2"; shift 2 ;;
    --install-dir) INSTALL_DIR="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage 0 ;;
    *) echo "Unknown: $1" >&2; usage 1 ;;
  esac
done

[[ -n "$HOST" && -n "$ROLE" && -n "$THIS_IP" ]] || { echo "Need --host --role --ip" >&2; usage 1; }
[[ "$ROLE" != "worker" || -n "$MAIN_IP" ]] || { echo "Worker needs --main-ip" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

RSYNC_OPTS=(-az --delete --exclude data --exclude .env --exclude '__pycache__' --exclude '.git')
[[ -n "$DRY_RUN" ]] && RSYNC_OPTS+=(--dry-run)

echo "=== Upload project -> ${HOST}:${INSTALL_DIR} ==="
ssh "$HOST" "mkdir -p $(dirname "$INSTALL_DIR")"
rsync "${RSYNC_OPTS[@]}" "$PROJECT_ROOT/" "${HOST}:${INSTALL_DIR}/"

echo "=== Run install-node.sh on server ==="
INSTALL_CMD="cd ${INSTALL_DIR} && chmod +x scripts/*.sh update 2>/dev/null; sudo ./scripts/install-node.sh --role ${ROLE} --ip ${THIS_IP} --non-interactive --skip-firewall"
if [[ "$ROLE" == "worker" ]]; then
  INSTALL_CMD+=" --main-ip ${MAIN_IP} --worker-role ${WORKER_ROLE}"
fi

if [[ -n "$DRY_RUN" ]]; then
  echo "Would run: $INSTALL_CMD"
  exit 0
fi

ssh -t "$HOST" "$INSTALL_CMD"

echo
echo "=== Done: ${HOST} (${ROLE}) ==="
if [[ "$ROLE" == "main" ]]; then
  echo "Admin: http://${THIS_IP}:9201/enrollment"
fi
if [[ "$ROLE" == "worker" ]]; then
  echo "Approve node at: http://${MAIN_IP}:9201/enrollment"
fi
echo "Update later: ssh ${HOST} 'cd ${INSTALL_DIR} && ./scripts/node-update.sh'"
