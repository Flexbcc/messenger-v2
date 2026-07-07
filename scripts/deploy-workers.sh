#!/usr/bin/env bash
# From MAIN: SSH to each worker in workers.list → node-update.sh (autodeploy chain).
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
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=30 -o StrictHostKeyChecking=accept-new)
if [[ -f "$ORCH_KEY" ]]; then
  SSH_OPTS+=(-i "$ORCH_KEY" -o IdentitiesOnly=yes)
fi

INSTALL_DIR="${DEPLOY_ROOT}"
FAIL=0

for host in "${WORKERS[@]}"; do
  echo "=== Worker deploy: ${host} ==="
  if ssh "${SSH_OPTS[@]}" "$host" \
    "cd ${INSTALL_DIR} && ./scripts/node-update.sh"; then
    echo "=== Worker OK: ${host} ==="
  else
    echo "=== Worker FAIL: ${host} ===" >&2
    FAIL=$((FAIL + 1))
  fi
done

if [[ "$FAIL" -gt 0 ]]; then
  echo "${FAIL} worker(s) failed — see log above" >&2
  exit 1
fi

echo "All ${#WORKERS[@]} worker(s) updated."
