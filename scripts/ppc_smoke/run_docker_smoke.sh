#!/usr/bin/env bash
# Docker integration smoke: discovery + relay-node; proves PPC invoke routing (502 offline).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.smoke.yml"
RELAY_HEALTH_URL="http://localhost:8005/health"
INVOKE_URL="http://localhost:8005/relay/ppc/test-storage-id/invoke"

cleanup() {
  docker compose -f "${COMPOSE_FILE}" down 2>/dev/null || true
}
trap cleanup EXIT

mkdir -p "${SCRIPT_DIR}/.data/discovery" "${SCRIPT_DIR}/.data/relay"

echo "==> docker compose up (discovery + relay)"
docker compose -f "${COMPOSE_FILE}" up -d --build

echo "==> wait for relay /health"
ready=false
for _ in $(seq 1 90); do
  if curl -sf "${RELAY_HEALTH_URL}" >/dev/null 2>&1; then
    ready=true
    break
  fi
  sleep 1
done
if [[ "${ready}" != true ]]; then
  echo "FAIL: relay did not become healthy at ${RELAY_HEALTH_URL}" >&2
  docker compose -f "${COMPOSE_FILE}" logs relay-node >&2 || true
  exit 1
fi

python3 -c "import httpx" 2>/dev/null || python3 -m pip install -q httpx

echo "==> POST ${INVOKE_URL} (expect 502 PPC agent offline)"
python3 - <<'PY'
import sys

import httpx

url = "http://localhost:8005/relay/ppc/test-storage-id/invoke"
resp = httpx.post(url, json={}, timeout=10.0)
if resp.status_code != 502:
    print(f"FAIL: expected 502, got {resp.status_code}: {resp.text}", file=sys.stderr)
    sys.exit(1)
detail = resp.json().get("detail", "")
if "offline" not in str(detail).lower():
    print(f"FAIL: expected offline detail, got: {detail!r}", file=sys.stderr)
    sys.exit(1)
print("invoke offline check passed (relay router OK)")
PY

echo "Docker smoke passed."
