#!/bin/bash
set -eu

mkdir -p \
  /data/home /data/discovery /data/storage /data/media /data/media-meta \
  /data/identity /data/runtime

# Create the shared identity before module processes start. This also performs
# the explicitly scoped one-time migration for early unified-node volumes that
# contain an Operational Certificate but predate the credential-chain file.
python /runtime/bootstrap_identity.py

# Home and Storage validate Discovery-signed user ownership records. In the
# unified process they must trust the active key from this same Discovery DB;
# an empty/stale .env value otherwise makes every buffer drain fail with 403.
discovery_signing_public_key="$(
  cd /runtime/modules/discovery
  PYTHONPATH=/runtime/modules/discovery:/runtime python -c '
from app.config import DISCOVERY_SIGNING_KEY_PATH
from app.db import init_db
from app.key_rotation import bootstrap_key_from_file, get_active_public_key_b64
init_db()
bootstrap_key_from_file(DISCOVERY_SIGNING_KEY_PATH)
print(get_active_public_key_b64())
'
)"
export DISCOVERY_SIGNING_PUBLIC_KEYS="$discovery_signing_public_key"

pids=""

start_module() {
  name="$1"
  port="$2"
  registration="$3"
  echo "[ouo-node] starting ${name} module on :${port}"
  (
    cd "/runtime/modules/${name}"
    NODE_REGISTRATION_ENABLED="$registration" \
      exec uvicorn app.main:app --host 0.0.0.0 --port "$port"
  ) &
  pids="$pids $!"
}

shutdown() {
  trap - TERM INT EXIT
  [ -z "$pids" ] || kill $pids 2>/dev/null || true
  wait || true
}

trap shutdown TERM INT EXIT

# Discovery owns the registry. Home is the sole aggregate registration agent;
# data-plane modules share its Node Root and must never register as nodes.
start_module discovery 8003 false
start_module storage 8002 false
start_module media 8004 false
start_module relay 8005 false
start_module home 8001 true

# Exit the whole node if any mandatory module exits. Docker restarts one
# coherent node instead of leaving a partially alive set of containers.
wait -n
status=$?
echo "[ouo-node] a mandatory module stopped (status=${status}); stopping node" >&2
exit "$status"
