#!/usr/bin/env bash
# Fast PPC-related unit checks — no Docker, no running services.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOME_NODE="${REPO_ROOT}/backend/services/home-node"

cd "${HOME_NODE}"
echo "==> pytest tests/test_storage_policy.py (home-node)"
python3 -m pytest tests/test_storage_policy.py -q

echo "Unit smoke passed."
