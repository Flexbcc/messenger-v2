#!/usr/bin/env bash
# End-to-end autodeploy smoke test from laptop.
#
# Usage:
#   ./scripts/test-autodeploy.sh
set -euo pipefail

MARKER="autodeploy-test-$(date +%s)"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"
# shellcheck source=lib/laptop-env.sh
source "$SCRIPT_DIR/lib/laptop-env.sh"
load_laptop_env "$PROJECT_ROOT"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) MAIN_HOST="$2"; shift 2 ;;
    --worker) WORKER_HOST="$2"; shift 2 ;;
    -h|--help) sed -n '2,6p' "$0"; exit 0 ;;
    *) echo "Unknown: $1" >&2; exit 1 ;;
  esac
done

echo "=== 1) Push test commit ==="
echo "$MARKER" > .autodeploy-marker
git add .autodeploy-marker
git commit -m "test: $MARKER" || true
git push origin main

echo "=== 2) Wait for webhook (35s) ==="
sleep 35

echo "=== 3) Main deploy log ==="
laptop_ssh "$MAIN_HOST" "tail -n 50 /var/log/messenger-deploy.log 2>/dev/null || echo 'no log yet'"

echo "=== 4) Main health ==="
laptop_ssh "$MAIN_HOST" "curl -sf http://localhost:8003/health && echo && curl -sf http://localhost:8007/health && echo && curl -sf http://localhost:9201/health && echo"

echo "=== 5) Worker health ==="
laptop_ssh "$WORKER_HOST" "curl -sf http://localhost:8001/health && echo && curl -sf http://localhost:8004/health && echo" || \
  echo "WARN: worker health failed"

echo "=== 6) Marker on servers ==="
laptop_ssh "$MAIN_HOST" "grep -F '$MARKER' /opt/messenger/project/.autodeploy-marker 2>/dev/null && echo MAIN OK || echo MAIN marker missing"
laptop_ssh "$WORKER_HOST" "grep -F '$MARKER' /opt/messenger/project/.autodeploy-marker 2>/dev/null && echo WORKER OK || echo WORKER marker missing"

echo "=== Done ==="
