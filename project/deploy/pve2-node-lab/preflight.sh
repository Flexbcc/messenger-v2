#!/bin/sh
set -eu

base_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
env_file=${1:-"$base_dir/.env"}

if [ ! -f "$env_file" ]; then
  echo "missing env file: $env_file" >&2
  exit 1
fi

if grep -Eq '(^|=)(REPLACE_|changeme|dev-secret)' "$env_file"; then
  echo "env file still contains placeholder secrets" >&2
  exit 1
fi

required='DISCOVERY_ADMIN_SECRET MESH_NOTIFY_SECRET JWT_SECRET GATEWAY_INVITE_SECRET TURN_SHARED_SECRET'
for name in $required; do
  value=$(sed -n "s/^${name}=//p" "$env_file" | tail -n 1)
  if [ "${#value}" -lt 32 ]; then
    echo "$name must contain at least 32 characters" >&2
    exit 1
  fi
done

docker compose --env-file "$env_file" -f "$base_dir/compose.yml" config --quiet
echo "compose and required secret shape are valid"
