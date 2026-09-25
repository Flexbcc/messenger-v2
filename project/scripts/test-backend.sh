#!/bin/sh
set -eu

OUO_PYTHON_BIN="${OUO_PYTHON_BIN:-python3}"

if ! "$OUO_PYTHON_BIN" -c 'import sys; raise SystemExit(0 if sys.version_info[:2] == (3, 11) else 1)'; then
  echo "Backend tests require Python 3.11; got: $("$OUO_PYTHON_BIN" --version 2>&1)" >&2
  echo "Set OUO_PYTHON_BIN to a Python 3.11 executable." >&2
  exit 2
fi

"$OUO_PYTHON_BIN" -m pytest -q tests shared/mesh/tests "$@"

PROJECT_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PYTHONPATH="$PROJECT_ROOT/services/home-node:$PROJECT_ROOT${PYTHONPATH:+:$PYTHONPATH}" \
  "$OUO_PYTHON_BIN" -m pytest -q services/home-node/tests "$@"

PYTHONPATH="$PROJECT_ROOT/services/storage-node:$PROJECT_ROOT${PYTHONPATH:+:$PYTHONPATH}" \
  "$OUO_PYTHON_BIN" -m pytest -q services/storage-node/tests "$@"

PYTHONPATH="$PROJECT_ROOT/services/relay-node:$PROJECT_ROOT${PYTHONPATH:+:$PYTHONPATH}" \
  "$OUO_PYTHON_BIN" -m pytest -q services/relay-node/tests "$@"
