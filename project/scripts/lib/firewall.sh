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
    echo "ufw not installed — open ports manually: 8003, 8007 (NOT 9201 — admin is localhost-only)" >&2
    return 0
  fi
  echo "Configuring firewall (main)..."
  firewall_ensure_ssh
  ufw allow 8003/tcp comment 'discovery' || true
  ufw allow 8007/tcp comment 'gateway' || true
  # Admin (:9201) is bound to 127.0.0.1 — use SSH tunnel. Never open 9201 to the internet.
  if [[ -n "$admin_ip" ]]; then
    echo "NOTE: admin_ip ignored — admin is localhost-only. Use: ssh -L 9201:127.0.0.1:9201 root@main" >&2
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
