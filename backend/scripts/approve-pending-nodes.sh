#!/usr/bin/env bash
# Approve pending nodes via discovery admin API (terminal, no web UI).
#
# Reads DISCOVERY_ADMIN_SECRET and DISCOVERY_PORT from .env in repo root.
# Sends header: X-Discovery-Admin-Secret
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/deploy-common.sh
source "$SCRIPT_DIR/lib/deploy-common.sh"

usage() {
  cat <<'EOF'
Approve pending nodes (discovery admin API).

Usage:
  approve-pending-nodes.sh              List pending, then approve all
  approve-pending-nodes.sh --list|-l      List pending only (no approve)
  approve-pending-nodes.sh NODE_ID ...    Approve specific node_id(s)
  approve-pending-nodes.sh --help|-h      Show this help

Environment (optional overrides for .env):
  DISCOVERY_ADMIN_SECRET   Required if not set in .env
  DISCOVERY_PORT           Default 8003 (from .env or fallback)

Operator UI: http://127.0.0.1:9205/ops (main-node) or :9201/enrollment (backend admin)

Examples:
  cd backend && ./scripts/approve-pending-nodes.sh --list
  cd backend && ./scripts/approve-pending-nodes.sh home-operator-main
EOF
}

LIST_ONLY=0
NODE_IDS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)
      usage
      exit 0
      ;;
    --list|-l)
      LIST_ONLY=1
      shift
      ;;
    --)
      shift
      NODE_IDS+=("$@")
      break
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      NODE_IDS+=("$1")
      shift
      ;;
  esac
done

deploy_cd_root

if [[ ! -f .env ]]; then
  echo "ERROR: Missing .env in $(pwd)" >&2
  echo "Copy .env.example and set DISCOVERY_ADMIN_SECRET." >&2
  exit 1
fi

if [[ -z "${DISCOVERY_PORT:-}" ]]; then
  DISCOVERY_PORT=$(grep '^DISCOVERY_PORT=' .env 2>/dev/null | cut -d= -f2- || echo 8003)
fi
if [[ -z "${DISCOVERY_ADMIN_SECRET:-}" ]]; then
  SECRET=$(grep '^DISCOVERY_ADMIN_SECRET=' .env 2>/dev/null | cut -d= -f2- || true)
else
  SECRET="$DISCOVERY_ADMIN_SECRET"
fi
DISCOVERY_URL="http://127.0.0.1:${DISCOVERY_PORT}"

if [[ -z "$SECRET" ]]; then
  echo "ERROR: DISCOVERY_ADMIN_SECRET not set." >&2
  echo "Add it to .env or export DISCOVERY_ADMIN_SECRET before running this script." >&2
  exit 1
fi

_admin_curl() {
  local method="$1"
  local path="$2"
  local tmp body code
  tmp=$(mktemp)
  if ! code=$(curl -sS -w "%{http_code}" -o "$tmp" -X "$method" "${DISCOVERY_URL}${path}" \
    -H "X-Discovery-Admin-Secret: ${SECRET}" \
    -H "Content-Type: application/json" 2>"$tmp.err"); then
    echo "ERROR: Cannot reach discovery at ${DISCOVERY_URL}" >&2
    [[ -s "$tmp.err" ]] && cat "$tmp.err" >&2
    echo "Is discovery-node running? (docker compose ps discovery-node)" >&2
    rm -f "$tmp" "$tmp.err"
    exit 1
  fi
  body=$(cat "$tmp")
  rm -f "$tmp" "$tmp.err"
  if [[ "$code" == "401" ]]; then
    echo "ERROR: HTTP 401 — invalid DISCOVERY_ADMIN_SECRET (check .env matches discovery-node)." >&2
    exit 1
  fi
  if [[ "$code" == "503" ]]; then
    echo "ERROR: HTTP 503 — admin API disabled on discovery (set DISCOVERY_ADMIN_SECRET on discovery-node)." >&2
    exit 1
  fi
  if [[ "$code" -lt 200 || "$code" -ge 300 ]]; then
    echo "ERROR: HTTP ${code} ${method} ${path}" >&2
    [[ -n "$body" ]] && echo "$body" >&2
    exit 1
  fi
  echo "$body"
}

approve_one() {
  local node_id="$1"
  echo "Approving ${node_id}..."
  local resp
  resp=$(_admin_curl POST "/admin/registry/nodes/${node_id}/approve")
  echo "$resp" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
except json.JSONDecodeError:
    print(sys.stdin.read())
    sys.exit(0)
print(f\"  -> trust_status={d.get('trust_status')}  {d.get('message', '')}\")
"
}

fetch_nodes_json() {
  _admin_curl GET "/admin/registry/nodes"
}

print_pending_table() {
  local list_json="$1"
  echo "$list_json" | python3 -c "
import json, sys
data = json.load(sys.stdin)
nodes = [n for n in data.get('nodes', []) if n.get('trust_status') == 'pending']
if not nodes:
    print('No pending nodes.', file=sys.stderr)
    sys.exit(0)
print(f'Pending nodes ({len(nodes)}):', file=sys.stderr)
print(f\"{'node_id':<28} {'cluster_id':<16} trust\", file=sys.stderr)
print('-' * 56, file=sys.stderr)
for n in nodes:
    print(f\"{n.get('node_id','?'):<28} {n.get('cluster_id','?'):<16} pending\", file=sys.stderr)
for n in nodes:
    print(n['node_id'])
"
}

if [[ ${#NODE_IDS[@]} -gt 0 ]]; then
  for id in "${NODE_IDS[@]}"; do
    approve_one "$id"
  done
  exit 0
fi

list_json=$(fetch_nodes_json)
pending_ids=$(print_pending_table "$list_json" || true)

if [[ -z "$pending_ids" ]]; then
  exit 0
fi

if [[ "$LIST_ONLY" -eq 1 ]]; then
  exit 0
fi

while read -r id; do
  [[ -n "$id" ]] && approve_one "$id"
done <<< "$pending_ids"

echo "Done. Nodes will claim node_token on next enrollment poll (check service logs)."
