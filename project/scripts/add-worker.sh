#!/usr/bin/env bash
# Add worker host to main workers.list (idempotent).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/deploy-common.sh
source "$SCRIPT_DIR/lib/deploy-common.sh"
# shellcheck source=lib/ssh-keys.sh
source "$SCRIPT_DIR/lib/ssh-keys.sh"

[[ $# -eq 1 ]] || { echo "Usage: $0 user@host" >&2; exit 1; }
deploy_cd_root
add_workers_list_entry "$1"
