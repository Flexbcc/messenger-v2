#!/usr/bin/env bash
# One-command deploy on the server (manual or via Gitea webhook).
#
# Usage on server:
#   cd /opt/messenger/project && ./deploy.sh
#
# Does: git pull → docker compose build/up → health checks → prune old images.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

./scripts/node-update.sh "$@"

docker image prune -f >/dev/null 2>&1 || true
echo "Deploy finished at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
