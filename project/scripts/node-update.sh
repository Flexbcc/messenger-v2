#!/usr/bin/env bash
# One-command update for any node (main or worker).
#
# First time: init-main-server.sh or bootstrap-worker.sh
# Every update:  ./scripts/node-update.sh
#
# Optional:
#   RELEASE_ENV=config/releases/home-1-0.2.0.env ./scripts/node-update.sh
#   ./scripts/node-update.sh home-node storage-node   # override services
set -euo pipefail

if [[ "${OUO_PUBLIC_UPDATE_MODE:-false}" = true ]]; then
  echo "Legacy git-based node-update is disabled in public update mode." >&2
  echo "Use prepare-secure-node-update.py and an approved atomic installer." >&2
  exit 78
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/deploy-common.sh
source "$SCRIPT_DIR/lib/deploy-common.sh"

deploy_cd_root
load_node_profile

if [[ -n "${RELEASE_ENV:-}" ]]; then
  apply_release_env "$RELEASE_ENV"
elif [[ -f "${DEPLOY_ROOT}/config/deploy/release.env" ]]; then
  apply_release_env "${DEPLOY_ROOT}/config/deploy/release.env"
fi

git_sync

if [[ $# -gt 0 ]]; then
  SERVICES=("$@")
else
  profile_services_array
fi

compose_update "${SERVICES[@]}"

echo
echo "Health checks..."
load_node_profile
if [[ -n "${HEALTH_URLS:-}" ]]; then
  # shellcheck disable=SC2206
  wait_health_urls ${HEALTH_URLS}
else
  for svc in "${SERVICES[@]}"; do
    case "$svc" in
      discovery-node) wait_health_urls "http://localhost:${DISCOVERY_PORT:-8003}/health" ;;
      home-node)      wait_health_urls "http://localhost:${HOME_PORT:-8001}/health" ;;
      gateway-node)   wait_health_urls "http://localhost:${GATEWAY_PORT:-8007}/health" ;;
      media-node)     wait_health_urls "http://localhost:${MEDIA_PORT:-8004}/health" ;;
      turn-node)      wait_health_urls "http://localhost:${TURN_PORT:-8006}/health" ;;
      admin)          wait_health_urls "http://localhost:${ADMIN_PORT:-9201}/health" ;;
    esac
  done
fi

if [[ -x "${DEPLOY_ROOT}/scripts/integration-smoke.sh" ]]; then
  echo
  "${DEPLOY_ROOT}/scripts/integration-smoke.sh" || true
fi

echo
docker compose ps "${SERVICES[@]}"
echo "Update complete."
