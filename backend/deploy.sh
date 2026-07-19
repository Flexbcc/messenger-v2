#!/usr/bin/env bash
# Full autodeploy entry (Gitea webhook or manual). Main → workers automatically.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

LOG="${DEPLOY_LOG:-/var/log/messenger-deploy.log}"
STATUS_FILE="${DEPLOY_ROOT:-$ROOT}/config/deploy/last-deploy.status"
DEPLOY_ROOT="$ROOT"
export DEPLOY_ROOT

mkdir -p "$(dirname "$STATUS_FILE")"

_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

_run() {
  local phase="$1"
  shift
  echo "[$(_ts)] $phase: $*"
  "$@"
}

{
  echo ""
  echo "========== deploy start $(_ts) pid=$$ =========="
  _run main-update ./scripts/node-update.sh "$@" || { echo "FAIL main node-update"; exit 1; }

  WORKER_RC=0
  if [[ -f scripts/deploy-workers.sh ]]; then
    _run workers ./scripts/deploy-workers.sh || WORKER_RC=$?
  fi

  docker image prune -f >/dev/null 2>&1 || true

  if [[ "$WORKER_RC" -eq 0 ]]; then
    echo "[$(_ts)] deploy finished OK"
    echo "status=ok time=$(_ts) commit=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)" > "$STATUS_FILE"
  else
    echo "[$(_ts)] deploy finished WITH WORKER ERRORS rc=$WORKER_RC"
    echo "status=worker_errors time=$(_ts) rc=$WORKER_RC" > "$STATUS_FILE"
    exit "$WORKER_RC"
  fi
} 2>&1 | tee -a "$LOG"
