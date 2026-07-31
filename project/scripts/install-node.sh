#!/usr/bin/env bash
# Full automatic setup on a fresh VPS (Docker, firewall, clone, services).
#
# === GitHub (recommended) ===
# 1) Push code to GitHub from laptop
# 2) On MAIN server:
#    curl -fsSL https://raw.githubusercontent.com/YOU/REPO/main/project/scripts/install-node.sh | sudo bash -s -- \
#      --role main --ip YOUR_MAIN_IP --git https://github.com/YOU/REPO.git --non-interactive
# 3) On each WORKER:
#    curl -fsSL ... | sudo bash -s -- \
#      --role worker --ip WORKER_IP --main-ip YOUR_MAIN_IP --worker-role full \
#      --git https://github.com/YOU/REPO.git --non-interactive
#
# === Updates (all servers, after code change) ===
#   cd /opt/messenger/project && ./scripts/node-update.sh
#
# Already copied project/ to server:
#   cd /opt/messenger/project && sudo ./scripts/install-node.sh --role main --ip 1.2.3.4 --non-interactive
set -euo pipefail

ROLE=""
THIS_IP=""
MAIN_IP=""
WORKER_ROLE="full"
GIT_URL=""
GIT_BRANCH="main"
INSTALL_DIR="${INSTALL_DIR:-/opt/messenger/project}"
NONINTERACTIVE=""
SKIP_DOCKER=""
SKIP_FIREWALL=""
ADMIN_ALLOW_IP=""
RUN_UPDATE=1

usage() {
  sed -n '2,18p' "$0"
  echo
  echo "Options:"
  echo "  --role main|worker       required"
  echo "  --ip IP                  public IP of THIS server"
  echo "  --main-ip IP             main server IP (worker only)"
  echo "  --worker-role ROLE       home|storage|media|full (default: full)"
  echo "  --git URL                clone repo if install dir missing"
  echo "  --branch NAME            git branch (default: main)"
  echo "  --install-dir PATH       default: /opt/messenger/project"
  echo "  --admin-allow-ip IP      restrict admin :9201 to this IP (main)"
  echo "  --non-interactive        no prompts"
  echo "  --skip-docker            assume Docker installed"
  echo "  --skip-firewall          do not touch ufw"
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --role) ROLE="$2"; shift 2 ;;
    --ip) THIS_IP="$2"; shift 2 ;;
    --main-ip) MAIN_IP="$2"; shift 2 ;;
    --worker-role) WORKER_ROLE="$2"; shift 2 ;;
    --git) GIT_URL="$2"; shift 2 ;;
    --branch) GIT_BRANCH="$2"; shift 2 ;;
    --install-dir) INSTALL_DIR="$2"; shift 2 ;;
    --admin-allow-ip) ADMIN_ALLOW_IP="$2"; shift 2 ;;
    --non-interactive) NONINTERACTIVE=1; shift ;;
    --skip-docker) SKIP_DOCKER=1; shift ;;
    --skip-firewall) SKIP_FIREWALL=1; shift ;;
    --no-run-update) RUN_UPDATE=0; shift ;;
    -h|--help) usage 0 ;;
    *) echo "Unknown option: $1" >&2; usage 1 ;;
  esac
done

[[ -n "$ROLE" ]] || { echo "--role required" >&2; usage 1; }

if [[ $EUID -ne 0 ]]; then
  echo "Re-run with sudo for Docker and firewall." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/install-docker.sh
source "$SCRIPT_DIR/lib/install-docker.sh"
# shellcheck source=lib/firewall.sh
source "$SCRIPT_DIR/lib/firewall.sh"

apt-get install -y -qq git curl ufw rsync 2>/dev/null || true

if [[ -z "$SKIP_DOCKER" ]]; then
  install_docker_engine
fi

clone_repo() {
  local url="$1" dest="$2" branch="$3"
  mkdir -p "$(dirname "$dest")"
  if [[ -d "$dest/.git" ]]; then
    echo "Git repo already at $dest"
    return 0
  fi
  echo "Cloning $url -> $dest (branch $branch)..."
  if [[ -d "$dest" ]] && [[ -n "$(ls -A "$dest" 2>/dev/null)" ]]; then
    echo "Directory $dest exists but is not a git repo — move it aside first." >&2
    exit 1
  fi
  git clone --branch "$branch" --depth 1 "$url" "$dest.tmp"
  if [[ -f "$dest.tmp/project/docker-compose.yml" ]]; then
    mv "$dest.tmp/project" "$dest"
    rm -rf "$dest.tmp"
  elif [[ -f "$dest.tmp/docker-compose.yml" ]]; then
    mv "$dest.tmp" "$dest"
  else
    echo "No docker-compose.yml found after clone" >&2
    exit 1
  fi
}

if [[ -n "$GIT_URL" ]]; then
  clone_repo "$GIT_URL" "$INSTALL_DIR" "$GIT_BRANCH"
elif [[ ! -f "$INSTALL_DIR/docker-compose.yml" ]]; then
  SRC_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
  if [[ -f "$SRC_ROOT/docker-compose.yml" ]]; then
    echo "Copying $SRC_ROOT -> $INSTALL_DIR ..."
    mkdir -p "$(dirname "$INSTALL_DIR")"
    rsync -a --exclude data --exclude .env "$SRC_ROOT/" "$INSTALL_DIR/" 2>/dev/null \
      || cp -a "$SRC_ROOT/." "$INSTALL_DIR/"
  else
    echo "Set --git URL or run from project checkout." >&2
    exit 1
  fi
fi

cd "$INSTALL_DIR"
chmod +x scripts/*.sh update 2>/dev/null || true

if [[ -z "$THIS_IP" ]]; then
  if [[ -n "$NONINTERACTIVE" ]]; then
    THIS_IP=$(curl -fsSL -4 ifconfig.me 2>/dev/null || curl -fsSL -4 icanhazip.com 2>/dev/null || true)
  fi
  if [[ -z "$THIS_IP" ]]; then
    read -rp "Public IP of THIS server: " THIS_IP
  fi
fi

if [[ -z "$SKIP_FIREWALL" ]]; then
  case "$ROLE" in
    main) firewall_apply_main "$ADMIN_ALLOW_IP" ;;
    worker) firewall_apply_worker "$WORKER_ROLE" ;;
  esac
fi

export NONINTERACTIVE="${NONINTERACTIVE:-}"
export RUN_NODE_UPDATE="$([[ "$RUN_UPDATE" == "1" ]] && echo Y || echo n)"

case "$ROLE" in
  main)
    if [[ -n "$GIT_URL" ]]; then
      export USE_GITHUB_ONLY=1
    fi
    PUBLIC_IP="$THIS_IP" GIT_BRANCH="$GIT_BRANCH" NONINTERACTIVE="$NONINTERACTIVE" \
      "$INSTALL_DIR/scripts/init-main-server.sh"
    ;;
  worker)
    [[ -n "$MAIN_IP" ]] || { echo "--main-ip required for worker" >&2; exit 1; }
    MAIN_IP="$MAIN_IP" THIS_IP="$THIS_IP" WORKER_ROLE="$WORKER_ROLE" \
      GIT_URL="$GIT_URL" GIT_BRANCH="$GIT_BRANCH" \
      "$INSTALL_DIR/scripts/bootstrap-worker.sh"
    ;;
  *)
    echo "Unknown role: $ROLE" >&2
    exit 1
    ;;
esac

echo
echo "=== Install finished ==="
echo "Install dir: $INSTALL_DIR"
echo "Update anytime: cd $INSTALL_DIR && ./scripts/node-update.sh"
