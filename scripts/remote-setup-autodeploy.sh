#!/usr/bin/env bash
# Bootstrap MAIN autodeploy + enroll first worker (one command from laptop).
#
# Prereq: ./scripts/setup-laptop-ssh.sh and config/deploy/laptop.env
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/laptop-env.sh
source "$SCRIPT_DIR/lib/laptop-env.sh"
load_laptop_env "$(cd "$SCRIPT_DIR/.." && pwd)"

[[ -n "${GITEA_PASSWORD:-}" ]] || {
  echo "Set GITEA_PASSWORD in config/deploy/laptop.env" >&2
  exit 1
}

exec "$SCRIPT_DIR/enroll-worker.sh" \
  --main "$MAIN_HOST" \
  --main-ip "$MAIN_IP" \
  --worker "$WORKER_HOST" \
  --worker-ip "$WORKER_IP"
