#!/usr/bin/env bash
# Run all QA bot scenarios against a live home-node.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

export HOME_URL="${HOME_URL:-http://localhost:8001}"
export PYTHONUNBUFFERED=1

if ! curl -sf "${HOME_URL}/health" >/dev/null; then
  echo "FAIL: home not reachable at ${HOME_URL}/health" >&2
  exit 1
fi

mkdir -p reports
RESULTS=()
FAIL=0

run_one() {
  local script="$1"
  local name
  name="$(basename "$script" .py)"
  echo "-------- $name --------"
  if python3 "$script"; then
    RESULTS+=("$name|PASS")
  else
    RESULTS+=("$name|FAIL")
    FAIL=1
  fi
}

for script in scenarios/[0-9]*.py; do
  run_one "$script"
done

{
  echo "# QA bots — last run"
  echo
  echo "- home: \`${HOME_URL}\`"
  echo "- ts: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  echo "| Scenario | Status |"
  echo "|----------|--------|"
  for row in "${RESULTS[@]}"; do
    IFS='|' read -r name status <<<"$row"
    echo "| \`${name}\` | ${status} |"
  done
  echo
  echo "Bugs: \`reports/bugs.jsonl\` / \`reports/bugs.md\`"
} > reports/last_run.md

echo
echo "Wrote reports/last_run.md"
cat reports/last_run.md
exit "$FAIL"
