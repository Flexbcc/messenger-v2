#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
umask 077

runtime_dir="runtime"
env_file="$runtime_dir/lab.env"
mkdir -p "$runtime_dir/operator"

secret() {
  openssl rand -hex 32
}

touch "$env_file"
chmod 600 "$env_file"

ensure_secret() {
  local key="$1"
  if ! grep -q "^${key}=" "$env_file"; then
    printf '%s=%s\n' "$key" "$(secret)" >> "$env_file"
  fi
}

ensure_secret JWT_SECRET
ensure_secret DISCOVERY_ADMIN_SECRET
ensure_secret MESH_NOTIFY_SECRET
ensure_secret OWNER_PANEL_SECRET
ensure_secret GATEWAY_INVITE_SECRET
ensure_secret TURN_SHARED_SECRET
if ! grep -q '^DISCOVERY_SIGNING_PUBLIC_KEYS=' "$env_file"; then
  # Compose validates required substitutions before the one-shot
  # provisioner runs. This value is replaced with the real pinned keys.
  printf 'DISCOVERY_SIGNING_PUBLIC_KEYS=provisioning-placeholder\n' >> "$env_file"
fi

if [[ -f "$runtime_dir/operator/provisioned.json" ]] && \
   ! grep -q '"schema_version":5' "$runtime_dir/operator/provisioned.json"; then
  rm "$runtime_dir/operator/provisioned.json"
fi

if [[ ! -f "$runtime_dir/operator/provisioned.json" ]]; then
  docker compose --env-file "$env_file" --profile tools run --rm provisioner
fi

while IFS='=' read -r key value; do
  [[ -n "$key" ]] || continue
  temp_env="$env_file.tmp"
  awk -F= -v target="$key" -v replacement="$value" '
    $1 == target { print target "=" replacement; found=1; next }
    { print }
    END { if (!found) print target "=" replacement }
  ' "$env_file" > "$temp_env"
  chmod 600 "$temp_env"
  mv "$temp_env" "$env_file"
done < "$runtime_dir/operator/generated.env"

docker compose --env-file "$env_file" up -d --build \
  discovery-d1 discovery-d2 discovery-d3
docker compose --env-file "$env_file" --profile tools run --rm discovery-bootstrap
approve_nodes() {
  docker compose --env-file "$env_file" --profile tools run --rm approver \
    --ca-file /operator/tls-ca.crt \
    --origin https://discovery-d1:8003 \
    --origin https://discovery-d2:8003 \
    --origin https://discovery-d3:8003 \
    --expected "$1"
}
approve_nodes 3
docker compose --env-file "$env_file" up -d --build \
  home-a home-b home-c home-d home-e \
  storage-a storage-b relay-a relay-b
approve_nodes 12
# Do not let infrastructure requests warm a partial Discovery trust cache while
# the three Discovery processes restart. Their databases already contain the
# converged 12-node view at this point.
docker compose --env-file "$env_file" stop \
  home-a home-b home-c home-d home-e storage-a storage-b relay-a relay-b
for discovery in discovery-d1 discovery-d2 discovery-d3; do
  docker compose --env-file "$env_file" restart "$discovery"
  approve_nodes 12
done
docker compose --env-file "$env_file" start \
  home-a home-b home-c home-d home-e storage-a storage-b relay-a relay-b
docker compose --env-file "$env_file" ps
