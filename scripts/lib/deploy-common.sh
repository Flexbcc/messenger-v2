# Shared helpers for deploy/update scripts. Source from scripts/*, do not execute directly.
set -euo pipefail

DEPLOY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
NODE_PROFILE="${DEPLOY_ROOT}/config/deploy/node.profile"

deploy_cd_root() {
  cd "$DEPLOY_ROOT"
}

set_var() {
  local key="$1" value="$2"
  local env_file="${DEPLOY_ROOT}/.env"
  touch "$env_file"
  if grep -q "^${key}=" "$env_file" 2>/dev/null; then
    local tmp
    tmp=$(mktemp)
    awk -F= -v k="$key" -v v="$value" 'BEGIN{OFS="="} $1==k {print k,v; next} {print}' "$env_file" > "$tmp"
    mv "$tmp" "$env_file"
  else
    echo "${key}=${value}" >> "$env_file"
  fi
}

load_node_profile() {
  if [[ -f "$NODE_PROFILE" ]]; then
    # shellcheck disable=SC1090
    source "$NODE_PROFILE"
  fi
  NODE_SERVICES="${NODE_SERVICES:-}"
  GIT_REMOTE="${GIT_REMOTE:-origin}"
  GIT_BRANCH="${GIT_BRANCH:-main}"
}

apply_release_env() {
  local release_file="${1:-}"
  [[ -n "$release_file" && -f "$release_file" ]] || return 0
  echo "Applying release env: $release_file"
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue
    set_var "${line%%=*}" "${line#*=}"
  done < "$release_file"
}

git_sync() {
  if ! git -C "$DEPLOY_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "Not a git repo — skipping git pull (using files on disk)" >&2
    return 0
  fi
  echo "Git pull ($GIT_REMOTE/$GIT_BRANCH)..."
  git -C "$DEPLOY_ROOT" fetch "$GIT_REMOTE" "$GIT_BRANCH"
  git -C "$DEPLOY_ROOT" merge --ff-only "FETCH_HEAD" 2>/dev/null \
    || git -C "$DEPLOY_ROOT" pull --ff-only "$GIT_REMOTE" "$GIT_BRANCH"
}

compose_update() {
  local services=("$@")
  if [[ ${#services[@]} -eq 0 ]]; then
    echo "No services configured (set NODE_SERVICES in config/deploy/node.profile)" >&2
    exit 1
  fi
  echo "=== Docker update: ${services[*]} ==="
  docker compose pull "${services[@]}" 2>/dev/null || true
  docker compose build "${services[@]}"
  docker compose up -d "${services[@]}"
}

wait_health_urls() {
  local url
  for url in "$@"; do
    [[ -z "$url" ]] && continue
    local ok=false
    for _ in $(seq 1 25); do
      if curl -sf "$url" >/dev/null 2>&1; then
        echo "  OK $url"
        ok=true
        break
      fi
      sleep 2
    done
    if ! $ok; then
      echo "  WARN timeout: $url" >&2
    fi
  done
}

profile_services_array() {
  load_node_profile
  # shellcheck disable=SC2206
  SERVICES=( ${NODE_SERVICES} )
}
