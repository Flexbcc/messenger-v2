#!/usr/bin/env bash
# Build docker images, compute BUILD_HASH, sign release, write release.env (Phase D3).
#
# Usage:
#   ./scripts/build-release.sh [node_id] [software_version]
#   ./scripts/build-release.sh home-local 0.2.0
#
# Env: RELEASE_SIGNING_SECRET or RELEASE_SIGNING_PRIVATE_KEY (see sign-node-release.py)
set -euo pipefail

cd "$(dirname "$0")/.."

NODE_ID="${1:-${HOME_NODE_ID:-home-local}}"
SOFTWARE_VERSION="${2:-${NODE_SOFTWARE_VERSION:-0.1.0}}"
SERVICES="${RELEASE_SERVICES:-discovery-node home-node storage-node relay-node media-node turn-node gateway-node}"

echo "=== Build release: node_id=$NODE_ID version=$SOFTWARE_VERSION ==="

BUILD_HASH="$(./scripts/compute-build-hash.sh)"
echo "BUILD_HASH=$BUILD_HASH"

echo "Building services: $SERVICES"
docker compose build $SERVICES

SIGN_ARGS=(
  --node-id "$NODE_ID"
  --build-hash "$BUILD_HASH"
  --software-version "$SOFTWARE_VERSION"
)

if [[ -n "${RELEASE_SIGNING_PRIVATE_KEY:-}" ]]; then
  SIGN_ARGS+=(--algorithm ed25519 --private-key "$RELEASE_SIGNING_PRIVATE_KEY")
elif [[ -n "${RELEASE_SIGNING_SECRET:-}" ]]; then
  SIGN_ARGS+=(--algorithm hmac --secret "$RELEASE_SIGNING_SECRET")
else
  echo "warning: no RELEASE_SIGNING_SECRET / RELEASE_SIGNING_PRIVATE_KEY — signature skipped" >&2
  RELEASE_SIGNATURE=""
fi

if [[ -n "${RELEASE_SIGNING_PRIVATE_KEY:-}${RELEASE_SIGNING_SECRET:-}" ]]; then
  RELEASE_SIGNATURE="$(python3 scripts/sign-node-release.py "${SIGN_ARGS[@]}")"
else
  RELEASE_SIGNATURE=""
fi

mkdir -p config/releases
RELEASE_FILE="config/releases/${NODE_ID}-${SOFTWARE_VERSION}.env"
cat > "$RELEASE_FILE" <<EOF
# Generated $(date -u +%Y-%m-%dT%H:%M:%SZ) by scripts/build-release.sh
NODE_BUILD_HASH=${BUILD_HASH}
NODE_SOFTWARE_VERSION=${SOFTWARE_VERSION}
NODE_RELEASE_SIGNATURE=${RELEASE_SIGNATURE}
EOF

echo "Wrote $RELEASE_FILE"
echo
echo "Apply on target host (.env or export before compose up):"
cat "$RELEASE_FILE"
