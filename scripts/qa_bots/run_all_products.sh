#!/usr/bin/env bash
# Orchestrate messenger bots + node + storage; write coverage_summary.md
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
export HOME_URL="${HOME_URL:-http://localhost:8001}"
export DISCOVERY_URL="${DISCOVERY_URL:-http://localhost:8003}"

mkdir -p reports
FAIL=0

echo "==== catalog_gen ===="
python3 catalog_gen.py

echo "==== messenger bots ===="
if ./run_messenger_bots.sh; then
  echo "messenger OK"
else
  echo "messenger FAIL" >&2
  FAIL=1
fi

echo "==== node smoke ===="
if ./run_node_smoke.sh; then
  echo "node OK"
else
  echo "node FAIL" >&2
  FAIL=1
fi

echo "==== storage smoke ===="
if ./run_storage_smoke.sh; then
  echo "storage OK"
else
  echo "storage FAIL" >&2
  FAIL=1
fi

echo "==== coverage_report ===="
python3 coverage_report.py
python3 catalog_gen.py  # refresh matrix with probes after runs

echo
echo "======== COVERAGE SUMMARY ========"
cat reports/coverage_summary.md
exit "$FAIL"
