#!/usr/bin/env bash
# Full PPC E2E: docker discovery+relay, headless storage-app, pair, LAN blob, relay invoke.
# Local-first — requires Docker + Flutter/Dart SDK. See README.md.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.smoke.yml"
STORAGE_APP_DIR="${REPO_ROOT}/storage-app/app"
PAIR_HELPER="${SCRIPT_DIR}/ppc_e2e_pair.py"
BLOB_SCRIPT="${REPO_ROOT}/storage-app/tools/ppc_blob_smoke.py"

RELAY_URL="${PPC_RELAY_URL:-http://localhost:8005}"
DISCOVERY_URL="${PPC_DISCOVERY_URL:-http://localhost:8003}"
STORAGE_NODE_ID="${PPC_STORAGE_NODE_ID:-smoke-storage-pc}"
PPC_PORT="${PPC_PORT:-7345}"
PPC_ROOT="${PPC_ROOT:-${SCRIPT_DIR}/.data/ppc}"
PPC_USER_ID="${PPC_USER_ID:-smoke-e2e}"
LAN_HINT="127.0.0.1:${PPC_PORT}"
STORAGE_HEALTH_URL="http://127.0.0.1:${PPC_PORT}/ppc/health"
RELAY_HEALTH_URL="${RELAY_URL}/health"
INVOKE_URL="${RELAY_URL}/relay/ppc/${STORAGE_NODE_ID}/invoke"

DATA_DIR="${SCRIPT_DIR}/.data"
LOG_FILE="${DATA_DIR}/storage-app-headless.log"
SIGNING_KEY="${DATA_DIR}/node.ed25519.seed"

STORAGE_PID=""

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "FAIL: required command not found: $1" >&2
    exit 1
  fi
}

require_dart_runner() {
  if command -v flutter >/dev/null 2>&1; then
    echo "==> flutter pub get (storage-app)"
    (cd "${STORAGE_APP_DIR}" && flutter pub get --quiet)
    DART_RUNNER=(dart run)
    return 0
  fi
  if command -v dart >/dev/null 2>&1; then
    echo "==> dart pub get (storage-app)"
    if ! (cd "${STORAGE_APP_DIR}" && dart pub get); then
      echo "FAIL: dart pub get failed — storage-app needs Flutter SDK (flutter.dev)" >&2
      exit 1
    fi
    DART_RUNNER=(dart run)
    return 0
  fi
  echo "FAIL: E2E requires Flutter or Dart SDK (cd storage-app/app && dart run lib/headless_main.dart)" >&2
  exit 1
}

install_python_deps() {
  python3 -c "import httpx, nacl" 2>/dev/null && return 0
  echo "==> install Python deps (httpx, pynacl)"
  python3 -m pip install -q httpx pynacl
}

stop_storage_app() {
  if [[ -n "${STORAGE_PID}" ]] && kill -0 "${STORAGE_PID}" 2>/dev/null; then
    echo "==> stop headless storage-app (pid ${STORAGE_PID})"
    kill "${STORAGE_PID}" 2>/dev/null || true
    wait "${STORAGE_PID}" 2>/dev/null || true
  fi
  STORAGE_PID=""
}

cleanup() {
  stop_storage_app
  docker compose -f "${COMPOSE_FILE}" down 2>/dev/null || true
}
trap cleanup EXIT

mkdir -p "${DATA_DIR}/discovery" "${DATA_DIR}/relay" "${PPC_ROOT}"
: > "${LOG_FILE}"

require_cmd docker
require_cmd python3
require_cmd curl
require_dart_runner
install_python_deps

if ! docker info >/dev/null 2>&1; then
  echo "FAIL: Docker daemon not available" >&2
  exit 1
fi

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

echo "==> relay offline check (expect 502 before agent connects)"
python3 - <<PY
import sys
import httpx

url = "${INVOKE_URL}"
resp = httpx.post(url, json={}, timeout=10.0)
if resp.status_code != 502:
    print(f"FAIL: expected 502 offline, got {resp.status_code}: {resp.text}", file=sys.stderr)
    sys.exit(1)
print("relay offline check passed")
PY

echo "==> start headless storage-app"
export PPC_INSECURE_KEYS=1
export PPC_ROOT
export PPC_PORT
export PPC_RELAY_URL="${RELAY_URL}"
export PPC_STORAGE_NODE_ID="${STORAGE_NODE_ID}"
export PPC_DISCOVERY_URL="${DISCOVERY_URL}"

(
  cd "${STORAGE_APP_DIR}"
  "${DART_RUNNER[@]}" lib/headless_main.dart
) >>"${LOG_FILE}" 2>&1 &
STORAGE_PID=$!

echo "==> wait for storage-app /ppc/health on :${PPC_PORT}"
ready=false
for _ in $(seq 1 120); do
  if curl -sf "${STORAGE_HEALTH_URL}" >/dev/null 2>&1; then
    ready=true
    break
  fi
  if ! kill -0 "${STORAGE_PID}" 2>/dev/null; then
    echo "FAIL: headless storage-app exited early; log:" >&2
    tail -n 40 "${LOG_FILE}" >&2 || true
    exit 1
  fi
  sleep 1
done
if [[ "${ready}" != true ]]; then
  echo "FAIL: storage-app did not become healthy at ${STORAGE_HEALTH_URL}" >&2
  tail -n 40 "${LOG_FILE}" >&2 || true
  exit 1
fi

echo "==> wait for relay agent (invoke /ppc/health via relay)"
agent_ready=false
for _ in $(seq 1 60); do
  if python3 - <<PY
import base64, json, sys
import httpx

resp = httpx.post(
    "${INVOKE_URL}",
    json={"method": "GET", "path": "/ppc/health"},
    timeout=10.0,
)
if resp.status_code != 200:
    sys.exit(1)
data = resp.json()
if int(data.get("status") or 0) != 200:
    sys.exit(1)
body = json.loads(base64.b64decode(data.get("body_b64") or b"e30=").decode() or "{}")
if body.get("status") != "ok":
    sys.exit(1)
print("relay agent online:", json.dumps(body))
PY
  then
    agent_ready=true
    break
  fi
  sleep 1
done
if [[ "${agent_ready}" != true ]]; then
  echo "FAIL: relay agent did not connect for ${STORAGE_NODE_ID}" >&2
  tail -n 40 "${LOG_FILE}" >&2 || true
  docker compose -f "${COMPOSE_FILE}" logs relay-node >&2 || true
  exit 1
fi

echo "==> generate node signing key seed"
python3 - <<PY
import base64, os
from pathlib import Path
path = Path("${SIGNING_KEY}")
if not path.is_file():
    path.write_text(base64.urlsafe_b64encode(os.urandom(32)).decode(), encoding="utf-8")
print(f"signing key: {path}")
PY

echo "==> pair via ppc_e2e_pair.py (code from headless log)"
python3 "${PAIR_HELPER}" \
  --log "${LOG_FILE}" \
  --lan-hint "${LAN_HINT}" \
  --user-id "${PPC_USER_ID}" \
  --signing-key "${SIGNING_KEY}"

echo "==> blob round-trip via LAN (ppc_blob_smoke.py)"
python3 "${BLOB_SCRIPT}" \
  --user-id "${PPC_USER_ID}" \
  --signing-key "${SIGNING_KEY}" \
  --lan-hint "${LAN_HINT}"

echo "==> blob round-trip via relay (ppc_blob_smoke.py)"
python3 "${BLOB_SCRIPT}" \
  --user-id "${PPC_USER_ID}" \
  --signing-key "${SIGNING_KEY}" \
  --relay-url "${RELAY_URL}" \
  --storage-node-id "${STORAGE_NODE_ID}"

echo "E2E smoke passed."
