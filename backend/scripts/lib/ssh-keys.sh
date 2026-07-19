# SSH key helpers for orchestrator (main→worker) and git deploy keys.
set -euo pipefail

ensure_ssh_key() {
  local key_path="$1"
  local comment="$2"
  mkdir -p "$(dirname "$key_path")"
  if [[ ! -f "$key_path" ]]; then
    ssh-keygen -t ed25519 -f "$key_path" -N "" -C "$comment"
  fi
  chmod 600 "$key_path"
  chmod 644 "${key_path}.pub"
}

ensure_orchestrator_key() {
  local key="${1:-/root/.ssh/messenger_orchestrator}"
  ensure_ssh_key "$key" "messenger-orchestrator@$(hostname -s)"
}

ensure_deploy_git_key() {
  local key="${1:-/root/.ssh/messenger_deploy}"
  ensure_ssh_key "$key" "messenger-deploy@$(hostname -s)"
}

authorize_pubkey() {
  local pubkey="$1"
  local auth="${2:-/root/.ssh/authorized_keys}"
  mkdir -p "$(dirname "$auth")"
  touch "$auth"
  chmod 600 "$auth"
  if ! grep -qF "$pubkey" "$auth" 2>/dev/null; then
    echo "$pubkey" >> "$auth"
    echo "Authorized key added to $auth"
  fi
}

add_workers_list_entry() {
  local host="$1"
  local list_file="${2:-${DEPLOY_ROOT}/config/deploy/workers.list}"
  mkdir -p "$(dirname "$list_file")"
  touch "$list_file"
  if ! grep -qxF "$host" "$list_file" 2>/dev/null; then
    echo "$host" >> "$list_file"
    echo "Added to workers.list: $host"
  fi
}
