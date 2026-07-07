#!/usr/bin/env bash
# One-shot autodeploy setup for MAIN or WORKER.
#
# MAIN (194.67.92.147):
#   GITEA_PASSWORD=flex_password WORKER_HOST=root@161.104.18.45 \
#     ./scripts/setup-autodeploy.sh --role main
#
# WORKER (161.104.18.45):
#   MAIN_IP=194.67.92.147 THIS_IP=161.104.18.45 \
#     ./scripts/setup-autodeploy.sh --role worker
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/deploy-common.sh
source "$SCRIPT_DIR/lib/deploy-common.sh"

ROLE=""
MAIN_IP="${MAIN_IP:-194.67.92.147}"
THIS_IP="${THIS_IP:-161.104.18.45}"
WORKER_HOST="${WORKER_HOST:-root@161.104.18.45}"
GITEA_HOST="${GITEA_HOST:-194.67.92.147}"
GITEA_OWNER="${GITEA_OWNER:-flex}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --role) ROLE="$2"; shift 2 ;;
    --main-ip) MAIN_IP="$2"; shift 2 ;;
    --ip) THIS_IP="$2"; shift 2 ;;
    --worker-host) WORKER_HOST="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,12p' "$0"
      exit 0
      ;;
    *) echo "Unknown: $1" >&2; exit 1 ;;
  esac
done

[[ -n "$ROLE" ]] || { echo "--role main|worker required" >&2; exit 1; }
[[ $EUID -eq 0 ]] || { echo "Run as root on the server." >&2; exit 1; }

deploy_cd_root
chmod +x scripts/*.sh deploy.sh 2>/dev/null || true

case "$ROLE" in
  main)
    echo "=== MAIN autodeploy ==="
    "$SCRIPT_DIR/setup-server-git.sh"
    "$SCRIPT_DIR/setup-gitea-webhook.sh"

    mkdir -p config/deploy
    if [[ ! -f config/deploy/workers.list ]]; then
      echo "$WORKER_HOST" > config/deploy/workers.list
      echo "Created config/deploy/workers.list → $WORKER_HOST"
    fi

    if [[ ! -f config/deploy/node.profile ]]; then
      PUBLIC_IP="$MAIN_IP" NONINTERACTIVE=1 RUN_NODE_UPDATE=n \
        "$SCRIPT_DIR/init-main-server.sh" || true
    fi

    echo
    echo "IMPORTANT: add deploy key (printed above) to Gitea repo ${GITEA_OWNER}/messenger"
    echo "IMPORTANT: main must SSH to worker without password:"
    echo "  ssh-copy-id ${WORKER_HOST}"
    echo
    echo "Test: cd ${DEPLOY_ROOT} && ./deploy.sh"
    ;;
  worker)
    echo "=== WORKER autodeploy ==="
    GITEA_HOST="$GITEA_HOST" GITEA_OWNER="$GITEA_OWNER" "$SCRIPT_DIR/setup-server-git.sh"

    if [[ ! -f config/deploy/node.profile ]]; then
      MAIN_IP="$MAIN_IP" THIS_IP="$THIS_IP" WORKER_ROLE=full NONINTERACTIVE=1 RUN_NODE_UPDATE=n \
        "$SCRIPT_DIR/bootstrap-worker.sh" || true
    fi

    echo
    echo "IMPORTANT: add worker deploy key to Gitea (same repo)"
    echo "Worker updates when MAIN runs deploy.sh (via workers.list SSH)"
    echo "Or manual: cd ${DEPLOY_ROOT} && ./scripts/node-update.sh"
    ;;
  *)
    echo "Unknown role: $ROLE" >&2
    exit 1
    ;;
esac
