#!/usr/bin/env bash
# Bootstrap MAIN autodeploy + enroll first worker (one command from laptop).
#
# Usage:
#   GITEA_PASSWORD='flex_pass' ./scripts/remote-setup-autodeploy.sh
set -euo pipefail

MAIN_HOST="${MAIN_HOST:-root@194.67.92.147}"
WORKER_HOST="${WORKER_HOST:-root@161.104.18.45}"
MAIN_IP="${MAIN_IP:-194.67.92.147}"
WORKER_IP="${WORKER_IP:-161.104.18.45}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

[[ -n "${GITEA_PASSWORD:-}" ]] || {
  echo "Set GITEA_PASSWORD (Gitea user flex)." >&2
  exit 1
}

exec "$SCRIPT_DIR/enroll-worker.sh" \
  --main "$MAIN_HOST" \
  --main-ip "$MAIN_IP" \
  --worker "$WORKER_HOST" \
  --worker-ip "$WORKER_IP"
