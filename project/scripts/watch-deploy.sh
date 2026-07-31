#!/usr/bin/env bash
# After git push: watch deploy log on main until finished.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/laptop-env.sh
source "$SCRIPT_DIR/lib/laptop-env.sh"
load_laptop_env "$PROJECT_ROOT"

echo "Watching /var/log/messenger-deploy.log on ${MAIN_HOST} (Ctrl+C to stop)…"
laptop_ssh "$MAIN_HOST" "tail -f /var/log/messenger-deploy.log"
