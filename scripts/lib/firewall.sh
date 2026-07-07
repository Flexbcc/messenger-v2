# UFW firewall rules per deploy role. Source from install-node.sh.
set -euo pipefail

firewall_ensure_ssh() {
  if command -v ufw >/dev/null 2>&1; then
    ufw allow OpenSSH >/dev/null 2>&1 || ufw allow 22/tcp comment 'SSH' || true
  fi
}

firewall_apply_main() {
  local admin_ip="${1:-}"
  if ! command -v ufw >/dev/null 2>&1; then
    echo "ufw not installed — open ports manually: 8003, 8007, 9201" >&2
    return 0
  fi
  echo "Configuring firewall (main)..."
  firewall_ensure_ssh
  ufw allow 8003/tcp comment 'discovery' || true
  ufw allow 8007/tcp comment 'gateway' || true
  if [[ -n "$admin_ip" ]]; then
    ufw allow from "$admin_ip" to any port 9201 proto tcp comment 'admin' || true
  else
    ufw allow 9201/tcp comment 'admin' || true
    echo "WARN: admin port 9201 open to all — set ADMIN_ALLOW_IP to restrict" >&2
  fi
  ufw --force enable || true
  ufw status || true
}

firewall_apply_worker() {
  local role="${1:-full}"
  if ! command -v ufw >/dev/null 2>&1; then
    echo "ufw not installed — open worker ports manually" >&2
    return 0
  fi
  echo "Configuring firewall (worker: $role)..."
  firewall_ensure_ssh
  case "$role" in
    home|full)
      ufw allow 8001/tcp comment 'home' || true
      ;;
  esac
  case "$role" in
    media|full)
      ufw allow 8004/tcp comment 'media' || true
      ;;
  esac
  case "$role" in
    full)
      ufw allow 8006/tcp comment 'turn' || true
      ;;
  esac
  # storage (8002) and relay (8005) stay internal — do NOT expose
  ufw --force enable || true
  ufw status || true
}
