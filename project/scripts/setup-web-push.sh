#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
KEY_DIR="$PROJECT_DIR/data/push"
PRIVATE_KEY="$KEY_DIR/vapid_private.pem"
ENV_FILE="$PROJECT_DIR/.env"

mkdir -p "$KEY_DIR"
chmod 700 "$KEY_DIR"

if [[ ! -s "$PRIVATE_KEY" ]]; then
  openssl ecparam -name prime256v1 -genkey -noout -out "$PRIVATE_KEY"
  chmod 600 "$PRIVATE_KEY"
fi

# Web Push applicationServerKey is the uncompressed P-256 point (65 bytes),
# encoded as URL-safe base64 without padding. SPKI DER ends with that point.
PUBLIC_KEY="$({ openssl ec -in "$PRIVATE_KEY" -pubout -outform DER 2>/dev/null; } | tail -c 65 | openssl base64 -A | tr '+/' '-_' | tr -d '=')"
if [[ -z "$PUBLIC_KEY" ]]; then
  echo "Could not derive VAPID public key" >&2
  exit 1
fi

touch "$ENV_FILE"
python3 - "$ENV_FILE" "$PUBLIC_KEY" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
public_key = sys.argv[2]
updates = {
    "VAPID_PRIVATE_KEY": "/data/vapid_private.pem",
    "VAPID_PUBLIC_KEY": public_key,
    "VAPID_SUBJECT": "mailto:admin@localhost",
}
lines = path.read_text().splitlines()
seen = set()
result = []
for line in lines:
    key = line.split("=", 1)[0] if "=" in line else ""
    if key in updates:
        result.append(f"{key}={updates[key]}")
        seen.add(key)
    else:
        result.append(line)
if seen != updates.keys():
    result.extend(f"{key}={value}" for key, value in updates.items() if key not in seen)
path.write_text("\n".join(result) + "\n")
PY

echo "Web Push configured. Public VAPID key: $PUBLIC_KEY"
echo "Restart with: docker compose up -d --build push-proxy home-node"
