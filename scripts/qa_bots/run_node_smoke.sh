#!/usr/bin/env bash
# L4 node smoke: health + panel/ops + node-settings planned skip accounting.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
REPORTS="$ROOT/reports"
mkdir -p "$REPORTS"
OUT="$REPORTS/node_smoke.md"
FAIL=0
cd "$ROOT"

check() {
  local name="$1" url="$2" want="${3:-200}"
  local code
  code=$(curl -s -o /tmp/qa_node_body.txt -w '%{http_code}' "$url" || echo 000)
  if [[ "$code" == "$want" ]]; then
    echo "OK  $name ($code) $url"
    echo "- PASS \`$name\` — $code $url" >>"$OUT"
  else
    echo "FAIL $name (got $code want $want) $url" >&2
    echo "- FAIL \`$name\` — got $code want $want — $url" >>"$OUT"
    FAIL=1
  fi
}

{
  echo "# Node smoke"
  echo
  echo "- ts: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
} >"$OUT"

check "project_home_health" "http://localhost:8001/health"
check "client_home_health" "http://localhost:18011/health"
check "main_home_health" "http://localhost:9205/health"
check "discovery_health" "http://localhost:8003/health"
check "main_panel" "http://localhost:9205/panel"
check "main_ops" "http://localhost:9205/ops/"
check "main_ops_static" "http://localhost:9205/ops/static/style.css"
check "dev_admin" "http://127.0.0.1:9201/"

# Node settings accounting from matrix
python3 - <<'PY' >>"$OUT"
import json
import subprocess
import sys
from pathlib import Path
matrix = Path("reports/coverage_matrix.json")
if not matrix.exists():
    subprocess.check_call([sys.executable, "catalog_gen.py"])
data = json.loads(matrix.read_text())
live = [r for r in data["node"] if r.get("status") != "planned"]
planned = [r for r in data["node"] if r.get("status") == "planned"]
print()
print("## Node settings catalog")
print()
print(f"- live (env/config): **{len(live)}** — smoke assumes stack already configured")
print(f"- planned skipped: **{len(planned)}**")
for r in planned:
    print(f"  - `{r['id']}`")
PY

echo
echo "Wrote $OUT"
exit "$FAIL"
