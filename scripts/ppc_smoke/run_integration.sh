#!/usr/bin/env bash
# Optional E2E: pair + blob round-trip against a live storage-app.
# Skips with a message when required env vars are not set.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PAIR_SCRIPT="${REPO_ROOT}/storage-app/tools/ppc_pair_smoke.py"
BLOB_SCRIPT="${REPO_ROOT}/storage-app/tools/ppc_blob_smoke.py"

have_pair_payload=false
if [[ -n "${PPC_PAIR_PAYLOAD:-}" ]]; then
  have_pair_payload=true
elif [[ -n "${PPC_PAIR_PAYLOAD_FILE:-}" ]]; then
  have_pair_payload=true
fi

if [[ "${have_pair_payload}" != true ]] || [[ -z "${NODE_SIGNING_KEY:-}" ]] || [[ -z "${PPC_USER_ID:-}" ]]; then
  echo "SKIP integration: set PPC_PAIR_PAYLOAD or PPC_PAIR_PAYLOAD_FILE, NODE_SIGNING_KEY, and PPC_USER_ID"
  exit 0
fi

if [[ -n "${PPC_PAIR_PAYLOAD:-}" ]]; then
  pair_arg="${PPC_PAIR_PAYLOAD}"
else
  pair_arg="${PPC_PAIR_PAYLOAD_FILE}"
fi

echo "==> ppc_pair_smoke.py"
python3 "${PAIR_SCRIPT}" \
  --payload "${pair_arg}" \
  --user-id "${PPC_USER_ID}" \
  --signing-key "${NODE_SIGNING_KEY}"

have_blob_transport=false
if [[ -n "${PPC_LAN_HINT:-}" ]]; then
  have_blob_transport=true
elif [[ -n "${PPC_RELAY_URL:-}" && -n "${PPC_STORAGE_NODE_ID:-}" ]]; then
  have_blob_transport=true
fi

if [[ "${have_blob_transport}" != true ]]; then
  echo "SKIP blob smoke: set PPC_LAN_HINT or both PPC_RELAY_URL and PPC_STORAGE_NODE_ID"
  exit 0
fi

blob_args=(
  --user-id "${PPC_USER_ID}"
  --signing-key "${NODE_SIGNING_KEY}"
)

if [[ -n "${PPC_LAN_HINT:-}" ]]; then
  blob_args+=(--lan-hint "${PPC_LAN_HINT}")
else
  blob_args+=(--relay-url "${PPC_RELAY_URL}" --storage-node-id "${PPC_STORAGE_NODE_ID}")
fi

echo "==> ppc_blob_smoke.py"
python3 "${BLOB_SCRIPT}" "${blob_args[@]}"

echo "Integration smoke passed."
