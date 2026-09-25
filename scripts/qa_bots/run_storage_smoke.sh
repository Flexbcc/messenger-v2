#!/usr/bin/env bash
# L4 storage smoke — prefer fast unit tests; optional e2e if PPC_E2E=1.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$ROOT/../.." && pwd)"
REPORTS="$ROOT/reports"
mkdir -p "$REPORTS"
OUT="$REPORTS/storage_smoke.md"

{
  echo "# Storage smoke"
  echo
  echo "- ts: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
} >"$OUT"

FAIL=0
if "$REPO/scripts/ppc_smoke/run_unit.sh" >>"$OUT" 2>&1; then
  echo "- PASS ppc unit smoke" >>"$OUT"
  echo "OK  ppc unit smoke"
else
  echo "- FAIL ppc unit smoke" >>"$OUT"
  echo "FAIL ppc unit smoke" >&2
  FAIL=1
fi

if [[ "${PPC_E2E:-0}" == "1" ]]; then
  if "$REPO/scripts/ppc_smoke/run_e2e_smoke.sh" >>"$OUT" 2>&1; then
    echo "- PASS ppc e2e smoke" >>"$OUT"
  else
    echo "- FAIL ppc e2e smoke" >>"$OUT"
    FAIL=1
  fi
else
  echo "- SKIP ppc e2e (set PPC_E2E=1 to enable)" >>"$OUT"
fi

echo "Wrote $OUT"
exit "$FAIL"
