#!/usr/bin/env bash
# Fast PPC-related unit checks — no Docker, no running services.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOME_NODE="${REPO_ROOT}/project/services/home-node"

cd "${HOME_NODE}"
echo "==> pytest tests/test_storage_redundancy.py (home-node)"
PYTHON_BIN="${PYTHON_BIN:-$(command -v python3.11 || command -v python3)}"
"${PYTHON_BIN}" -m pytest tests/test_storage_redundancy.py -q

echo "Unit smoke passed."
