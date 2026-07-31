#!/usr/bin/env bash
# One-time: SSH keys from Mac -> main + worker (no more password prompts).
#
# Usage:
#   ./scripts/setup-laptop-ssh.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/laptop-env.sh
source "$SCRIPT_DIR/lib/laptop-env.sh"

load_laptop_env "$PROJECT_ROOT"
KEY="$LAPTOP_SSH_KEY"

if [[ ! -f "$KEY" ]]; then
  echo "Creating SSH key: $KEY"
  ssh-keygen -t ed25519 -f "$KEY" -N "" -C "messenger-ops@$(hostname -s)"
fi

echo "Copying key to servers (enter password ONE LAST TIME per server)..."
ssh-copy-id -i "${KEY}.pub" "$MAIN_HOST"
ssh-copy-id -i "${KEY}.pub" "$WORKER_HOST"

ENV_FILE="${PROJECT_ROOT}/config/deploy/laptop.env"
if [[ ! -f "$ENV_FILE" ]]; then
  cp "${PROJECT_ROOT}/config/deploy/laptop.env.example" "$ENV_FILE"
  echo
  echo "Created $ENV_FILE — set GITEA_PASSWORD there (one time)."
fi

echo
echo "Testing passwordless SSH..."
laptop_ssh "$MAIN_HOST" 'echo MAIN OK'
laptop_ssh "$WORKER_HOST" 'echo WORKER OK'
echo "Done. Scripts will use $KEY automatically."
