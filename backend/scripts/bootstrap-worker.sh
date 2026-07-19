#!/usr/bin/env bash
# First-time setup for a WORKER node (home / storage / media / relay / turn).
#
# Usage:
#   ./scripts/bootstrap-worker.sh
#   # or non-interactive:
#   MAIN_IP=203.0.113.10 THIS_IP=203.0.113.21 WORKER_ROLE=home ./scripts/bootstrap-worker.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/deploy-common.sh"

deploy_cd_root

if ! command -v docker >/dev/null 2>&1; then
  echo "Install Docker first." >&2
  exit 1
fi

MAIN_IP="${MAIN_IP:-}"
THIS_IP="${THIS_IP:-}"
WORKER_ROLE="${WORKER_ROLE:-}"
BARE_REPO="${DEPLOY_GIT_BARE:-/var/git/messenger.git}"
GIT_URL="${GIT_URL:-}"

if ! git -C "$DEPLOY_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if [[ -n "$GIT_URL" ]]; then
    echo "Cloning from $GIT_URL ..."
    mkdir -p "$(dirname "$DEPLOY_ROOT")"
    tmp="${DEPLOY_ROOT}.clone.$$"
    git clone --depth 1 "${GIT_BRANCH:+--branch "$GIT_BRANCH"}" "$GIT_URL" "$tmp"
    if [[ -f "$tmp/project/docker-compose.yml" ]]; then
      mv "$tmp/project" "$DEPLOY_ROOT"
      rm -rf "$tmp"
    else
      mv "$tmp" "$DEPLOY_ROOT"
    fi
    deploy_cd_root
  elif [[ -n "$MAIN_IP" ]]; then
    MAIN_USER="${MAIN_USER:-root}"
    if [[ "${NONINTERACTIVE:-}" != "1" ]]; then
      read -rp "SSH user on main server [root]: " MAIN_USER
      MAIN_USER=${MAIN_USER:-root}
    fi
    if [[ ! -f "${DEPLOY_ROOT}/docker-compose.yml" ]]; then
      echo "Cloning from ${MAIN_USER}@${MAIN_IP}:${BARE_REPO} ..."
      mkdir -p "$(dirname "$DEPLOY_ROOT")"
      git clone "ssh://${MAIN_USER}@${MAIN_IP}${BARE_REPO}" "$DEPLOY_ROOT"
      deploy_cd_root
    fi
  fi
fi

if [[ -z "$MAIN_IP" ]]; then
  read -rp "Public IP of MAIN server (discovery): " MAIN_IP
fi
if [[ -z "$THIS_IP" ]]; then
  read -rp "Public IP of THIS worker server: " THIS_IP
fi
if [[ -z "$WORKER_ROLE" ]]; then
  if [[ "${NONINTERACTIVE:-}" == "1" ]]; then
    WORKER_ROLE=full
  else
  echo "Worker role:"
  echo "  1) home    — users, messages, websocket"
  echo "  2) storage — offline buffer"
  echo "  3) media    — files"
  echo "  4) full     — home + storage + media + relay + turn (test node)"
  read -rp "Choice [4]: " choice
  case "${choice:-4}" in
    1) WORKER_ROLE=home ;;
    2) WORKER_ROLE=storage ;;
    3) WORKER_ROLE=media ;;
    4|*) WORKER_ROLE=full ;;
  esac
  fi
fi

HOST_SUFFIX=$(hostname -s 2>/dev/null || echo "node")

case "$WORKER_ROLE" in
  home)
    NODE_SERVICES="home-node"
    HOME_ID="home-${HOST_SUFFIX}"
    ;;
  storage)
    NODE_SERVICES="storage-node"
    ;;
  media)
    NODE_SERVICES="media-node"
    ;;
  full)
    NODE_SERVICES="home-node storage-node media-node relay-node turn-node"
    HOME_ID="home-${HOST_SUFFIX}"
    ;;
  *)
    echo "Unknown WORKER_ROLE=$WORKER_ROLE" >&2
    exit 1
    ;;
esac

mkdir -p config/deploy data/home data/storage data/media data/relay data/turn

cat > config/deploy/node.profile <<EOF
# Worker — generated $(date -u +%Y-%m-%dT%H:%M:%SZ)
DEPLOY_ROLE=worker
WORKER_ROLE=${WORKER_ROLE}
NODE_SERVICES="${NODE_SERVICES}"
GIT_REMOTE=origin
GIT_BRANCH=main
MAIN_IP=${MAIN_IP}
THIS_IP=${THIS_IP}
HEALTH_URLS="$( [[ "$NODE_SERVICES" == *home-node* ]] && echo -n "http://localhost:8001/health " )$( [[ "$NODE_SERVICES" == *media-node* ]] && echo -n "http://localhost:8004/health " )"
EOF

[[ -f .env ]] || cp .env.example .env

set_var "DISCOVERY_NODE_URL" "http://${MAIN_IP}:8003"
set_var "CLUSTER_ID" "default"
set_var "ENROLLMENT_MODE" "hybrid"
set_var "INTERNAL_SECURITY_MODE" "legacy"
set_var "FEDERATION_ENVELOPE_MODE" "legacy"
set_var "NODE_RESOURCE_POLICY" "federated"
set_var "JWT_SECRET" "change-me-sync-with-main-or-generate"

if [[ "$NODE_SERVICES" == *home-node* ]]; then
  set_var "HOME_NODE_ID" "${HOME_ID:-home-1}"
  set_var "HOME_NODE_PUBLIC_URL" "http://${THIS_IP}:8001"
  set_var "HOME_PORT" "8001"
  set_var "MEDIA_NODE_URL" "http://${THIS_IP}:8004"
  set_var "STORAGE_NODE_URL" "http://storage-node:8002"
fi
if [[ "$NODE_SERVICES" == *storage-node* ]]; then
  set_var "STORAGE_NODE_ID" "storage-${HOST_SUFFIX}"
  set_var "STORAGE_NODE_PUBLIC_URL" "http://${THIS_IP}:8002"
fi
if [[ "$NODE_SERVICES" == *media-node* ]]; then
  set_var "MEDIA_NODE_ID" "media-${HOST_SUFFIX}"
  set_var "MEDIA_NODE_PUBLIC_URL" "http://${THIS_IP}:8004"
fi
if [[ "$NODE_SERVICES" == *relay-node* ]]; then
  set_var "RELAY_NODE_ID" "relay-${HOST_SUFFIX}"
  set_var "RELAY_NODE_PUBLIC_URL" "http://relay-node:8005"
fi
if [[ "$NODE_SERVICES" == *turn-node* ]]; then
  set_var "TURN_NODE_ID" "turn-${HOST_SUFFIX}"
  set_var "TURN_NODE_PUBLIC_URL" "http://${THIS_IP}:8006"
  set_var "TURN_SHARED_SECRET" "change-me-turn-secret"
fi

echo
echo "=== Worker configured ($WORKER_ROLE) ==="
echo "Services: $NODE_SERVICES"
echo "Discovery: http://${MAIN_IP}:8003"
echo
echo "Daily update command:"
echo "  cd $(pwd) && ./scripts/node-update.sh"
echo
read -rp "Run node-update now? [Y/n] " RUN
if [[ "${NONINTERACTIVE:-}" == "1" ]]; then
  RUN="${RUN_NODE_UPDATE:-Y}"
fi
if [[ "${RUN:-Y}" =~ ^[Yy]$ ]]; then
  "$SCRIPT_DIR/node-update.sh"
fi

echo
echo "Approve pending nodes (terminal):"
echo "  ssh root@${MAIN_IP} 'cd /opt/messenger/project && ./scripts/approve-pending-nodes.sh'"
