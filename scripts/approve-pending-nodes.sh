#!/usr/bin/env bash
# Approve pending nodes via discovery admin API (terminal, no web UI).
#
# Usage on MAIN:
#   cd /opt/messenger/project && ./scripts/approve-pending-nodes.sh
#   ./scripts/approve-pending-nodes.sh home-cv7616931
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/deploy-common.sh
source "$SCRIPT_DIR/lib/deploy-common.sh"

deploy_cd_root

if [[ ! -f .env ]]; then
  echo "Missing .env" >&2
  exit 1
fi

DISCOVERY_PORT=$(grep '^DISCOVERY_PORT=' .env 2>/dev/null | cut -d= -f2- || echo 8003)
SECRET=$(grep '^DISCOVERY_ADMIN_SECRET=' .env 2>/dev/null | cut -d= -f2- || true)
DISCOVERY_URL="http://127.0.0.1:${DISCOVERY_PORT}"

if [[ -z "$SECRET" ]]; then
  echo "DISCOVERY_ADMIN_SECRET not set in .env" >&2
  exit 1
fi

approve_one() {
  local node_id="$1"
  echo "Approving ${node_id}..."
  curl -sf -X POST "${DISCOVERY_URL}/admin/registry/nodes/${node_id}/approve" \
    -H "X-Discovery-Admin-Secret: ${SECRET}"
  echo
}

if [[ $# -gt 0 ]]; then
  for id in "$@"; do
    approve_one "$id"
  done
  exit 0
fi

list_json=$(curl -sf "${DISCOVERY_URL}/admin/registry/nodes" \
  -H "X-Discovery-Admin-Secret: ${SECRET}")

pending_ids=$(echo "$list_json" | python3 -c "
import json, sys
data = json.load(sys.stdin)
pending = [n['node_id'] for n in data.get('nodes', []) if n.get('trust_status') == 'pending']
if not pending:
    print('No pending nodes.', file=sys.stderr)
    sys.exit(0)
print('Pending:', ', '.join(pending), file=sys.stderr)
for pid in pending:
    print(pid)
")

if [[ -z "$pending_ids" ]]; then
  exit 0
fi

while read -r id; do
  [[ -n "$id" ]] && approve_one "$id"
done <<< "$pending_ids"

echo "Done."
