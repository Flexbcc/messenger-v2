#!/usr/bin/env bash
# Messenger QA bots (smoke 01–09 + catalog L1/L2).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
export HOME_URL="${HOME_URL:-http://localhost:8001}"
export DISCOVERY_URL="${DISCOVERY_URL:-http://localhost:8003}"
exec "$ROOT/run_all.sh"
