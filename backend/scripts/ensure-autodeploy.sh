#!/usr/bin/env bash
# Verify autodeploy chain on MAIN (run from Mac).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/laptop-env.sh
source "$SCRIPT_DIR/lib/laptop-env.sh"
load_laptop_env "$PROJECT_ROOT"

INSTALL_DIR="/opt/messenger/project"
FAIL=0

_run() {
  local label="$1"
  shift
  echo -n "  $label … "
  if laptop_ssh "$MAIN_HOST" "$@" >/dev/null 2>&1; then
    echo OK
  else
    echo FAIL
    FAIL=$((FAIL + 1))
  fi
}

echo "=== Autodeploy checks (${MAIN_HOST}) ==="
_run "webhook systemd" "systemctl is-active messenger-deploy-webhook"
_run "webhook HTTP" "curl -sf http://127.0.0.1:9009/health"
_run "deploy.sh" "test -x ${INSTALL_DIR}/deploy.sh"
_run "workers.list" "test -s ${INSTALL_DIR}/config/deploy/workers.list"
_run "orchestrator key" "test -f /root/.ssh/messenger_orchestrator"
_run "deploy git key" "test -f /root/.ssh/messenger_deploy"
_run "git fetch" "cd ${INSTALL_DIR} && GIT_SSH_COMMAND='ssh -i /root/.ssh/messenger_deploy -o IdentitiesOnly=yes -F /root/.ssh/config' git fetch origin main"

WORKERS=$(laptop_ssh "$MAIN_HOST" "grep -v '^#' ${INSTALL_DIR}/config/deploy/workers.list 2>/dev/null | grep -v '^[[:space:]]*$' || true")
if [[ -z "$WORKERS" ]]; then
  echo "  worker SSH … SKIP (no workers)"
else
  while read -r host; do
    [[ -z "$host" ]] && continue
    _run "SSH → $host" "ssh -i /root/.ssh/messenger_orchestrator -o BatchMode=yes -o ConnectTimeout=15 $host echo ok"
  done <<< "$WORKERS"
fi

if [[ "$FAIL" -gt 0 ]]; then
  echo
  echo "FAILED ($FAIL). Fix: ./scripts/fix-autodeploy-main.sh"
  exit 1
fi

echo
echo "OK — push to Gitea deploys main + workers automatically."
