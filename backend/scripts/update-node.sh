#!/usr/bin/env bash
# Rolling update (legacy alias) — prefer: ./scripts/node-update.sh
#
# Usage:
#   ./scripts/node-update.sh
#   RELEASE_ENV=config/releases/home-local-0.2.0.env ./scripts/node-update.sh home-node
set -euo pipefail
exec "$(dirname "$0")/node-update.sh" "$@"
