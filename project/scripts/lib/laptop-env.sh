# Load laptop-side deploy secrets (gitignored). Source from scripts on Mac.
load_laptop_env() {
  local root="${1:-}"
  if [[ -z "$root" ]]; then
    root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  fi
  LAPTOP_ENV="${root}/config/deploy/laptop.env"
  if [[ -f "$LAPTOP_ENV" ]]; then
    # shellcheck disable=SC1090
    source "$LAPTOP_ENV"
  fi

  MAIN_HOST="${MAIN_HOST:-root@194.67.92.147}"
  WORKER_HOST="${WORKER_HOST:-root@161.104.18.45}"
  MAIN_IP="${MAIN_IP:-194.67.92.147}"
  WORKER_IP="${WORKER_IP:-161.104.18.45}"
  LAPTOP_SSH_KEY="${LAPTOP_SSH_KEY:-$HOME/.ssh/messenger_ops}"

  LAPTOP_SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=20)
  if [[ -f "$LAPTOP_SSH_KEY" ]]; then
    LAPTOP_SSH_OPTS+=(-i "$LAPTOP_SSH_KEY" -o IdentitiesOnly=yes)
  fi
}

laptop_ssh() {
  ssh "${LAPTOP_SSH_OPTS[@]}" "$@"
}

laptop_rsync() {
  rsync -e "ssh ${LAPTOP_SSH_OPTS[*]}" "$@"
}
