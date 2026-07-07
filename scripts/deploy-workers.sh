#!/usr/bin/env bash
# From MAIN server: SSH to each worker and run node-update.sh.
#
# Workers list: config/deploy/workers.list (one user@host per line)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/deploy-common.sh
source "$SCRIPT_DIR/lib/deploy-common.sh"

deploy_cd_root
WORKERS_FILE="${DEPLOY_ROOT}/config/deploy/workers.list"

if [[ ! -f "$WORKERS_FILE" ]]; then
  echo "No workers.list — skipping worker deploy."
  exit 0
fi

mapfile -t WORKERS < <(grep -v '^[[:space:]]*#' "$WORKERS_FILE" | grep -v '^[[:space:]]*$' || true)
if [[ ${#WORKERS[@]} -eq 0 ]]; then
  echo "workers.list is empty — skipping worker deploy."
  exit 0
fi

ORCH_KEY="${ORCHESTRATOR_SSH_KEY:-/root/.ssh/messenger_orchestrator}"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=15)
if [[ -f "$ORCH_KEY" ]]; then
  SSH_OPTS+=(-i "$ORCH_KEY" -o IdentitiesOnly=yes)
fi

INSTALL_DIR="${DEPLOY_ROOT}"
for host in "${WORKERS[@]}"; do
  echo "=== Worker deploy: ${host} ==="
  ssh "${SSH_OPTS[@]}" "$host" \
    "cd ${INSTALL_DIR} && ./scripts/node-update.sh"
done

echo "All workers updated."
