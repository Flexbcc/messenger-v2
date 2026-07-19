#!/usr/bin/env bash
# First-time setup for the MAIN server (static IP, discovery + gateway + admin + git bare).
#
# Usage (on VPS):
#   cd /opt/messenger/project && ./scripts/init-main-server.sh
#
# Creates:
#   /var/git/messenger.git     — bare repo (workers pull from here)
#   config/deploy/node.profile — services to run on THIS machine
#   .env                       — production-oriented defaults
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/deploy-common.sh"

deploy_cd_root

if ! command -v docker >/dev/null 2>&1; then
  echo "Install Docker first: https://docs.docker.com/engine/install/" >&2
  exit 1
fi

PUBLIC_IP="${PUBLIC_IP:-}"
if [[ -z "$PUBLIC_IP" ]]; then
  read -rp "Public IP or domain of THIS main server: " PUBLIC_IP
fi
if [[ -z "$PUBLIC_IP" ]]; then
  echo "Public IP is required." >&2
  exit 1
fi

GIT_BRANCH="${GIT_BRANCH:-}"
if [[ -z "$GIT_BRANCH" ]]; then
  read -rp "Git branch to deploy [main]: " GIT_BRANCH
fi
GIT_BRANCH=${GIT_BRANCH:-main}

if [[ -z "${DISCOVERY_ADMIN_SECRET:-}" ]]; then
  read -rp "DISCOVERY_ADMIN_SECRET (enrollment admin, leave empty to generate): " ADMIN_SECRET
else
  ADMIN_SECRET="$DISCOVERY_ADMIN_SECRET"
fi
if [[ -z "$ADMIN_SECRET" ]]; then
  ADMIN_SECRET=$(python3 -c "import secrets; print(secrets.token_urlsafe(32))" 2>/dev/null || openssl rand -base64 32)
  echo "Generated DISCOVERY_ADMIN_SECRET"
fi

if [[ -z "${JWT_SECRET:-}" ]]; then
  read -rp "JWT_SECRET (leave empty to generate): " JWT_SECRET
fi
if [[ -z "$JWT_SECRET" ]]; then
  JWT_SECRET=$(python3 -c "import secrets; print(secrets.token_urlsafe(32))" 2>/dev/null || openssl rand -base64 32)
fi

mkdir -p config/deploy data/discovery data/gateway data/admin

cat > config/deploy/node.profile <<EOF
# Main server — generated $(date -u +%Y-%m-%dT%H:%M:%SZ)
DEPLOY_ROLE=main
NODE_SERVICES="discovery-node gateway-node"
GIT_REMOTE=origin
GIT_BRANCH=${GIT_BRANCH}
PUBLIC_IP=${PUBLIC_IP}
HEALTH_URLS="http://localhost:8003/health http://localhost:8007/health"
EOF

[[ -f .env ]] || cp .env.example .env

set_var "DISCOVERY_NODE_URL" "http://discovery-node:8003"
set_var "DISCOVERY_PORT" "8003"
set_var "DISCOVERY_ADMIN_SECRET" "$ADMIN_SECRET"
set_var "ENROLLMENT_MODE" "hybrid"
set_var "INTERNAL_SECURITY_MODE" "legacy"
set_var "FEDERATION_ENVELOPE_MODE" "legacy"
set_var "JWT_SECRET" "$JWT_SECRET"
set_var "CLUSTER_ID" "default"
set_var "GATEWAY_NODE_ID" "gateway-1"
set_var "GATEWAY_NODE_PUBLIC_URL" "http://${PUBLIC_IP}:8007"
set_var "GATEWAY_DISCOVERY_PUBLIC_URL" "http://${PUBLIC_IP}:8003"
set_var "GATEWAY_PORT" "8007"
set_var "ADMIN_PORT" "9201"
set_var "HOME_NODE_PUBLIC_URL" "http://${PUBLIC_IP}:8001"

# Bare git repo for workers (optional — skip if using GitHub for all nodes)
SKIP_BARE_GIT="${SKIP_BARE_GIT:-}"
if [[ -z "$SKIP_BARE_GIT" && "${USE_GITHUB_ONLY:-}" != "1" ]]; then
BARE_REPO="${DEPLOY_GIT_BARE:-/var/git/messenger.git}"
if [[ ! -d "$BARE_REPO" ]]; then
  echo "Creating bare git repo at $BARE_REPO (may need sudo)..."
  sudo mkdir -p "$(dirname "$BARE_REPO")"
  sudo git init --bare "$BARE_REPO"
  sudo chown -R "$(whoami):$(id -gn)" "$(dirname "$BARE_REPO")" 2>/dev/null || true
fi

HOOK="$BARE_REPO/hooks/post-receive"
if [[ -d "$BARE_REPO/hooks" ]]; then
  cat > /tmp/messenger-post-receive <<HOOKEOF
#!/usr/bin/env bash
set -euo pipefail
while read -r _ _ ref; do
  if [[ "\$ref" != "refs/heads/${GIT_BRANCH}" ]]; then
    continue
  fi
  GIT_WORK_TREE=${DEPLOY_ROOT} git --git-dir=${BARE_REPO} checkout -f ${GIT_BRANCH}
  cd ${DEPLOY_ROOT} && ./scripts/node-update.sh
done
HOOKEOF
  cp /tmp/messenger-post-receive "$HOOK"
  chmod +x "$HOOK"
  echo "Installed post-receive hook (auto-deploy on git push to main)."
fi

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if ! git remote get-url origin >/dev/null 2>&1; then
    git remote add origin "$BARE_REPO" 2>/dev/null || true
  fi
fi
fi

echo
echo "=== Main server configured ==="
echo "Profile: config/deploy/node.profile"
if [[ -z "$SKIP_BARE_GIT" && "${USE_GITHUB_ONLY:-}" != "1" ]]; then
echo "Bare git: $BARE_REPO"
echo
echo "From your laptop (push to main server):"
echo "  git remote add production ssh://root@${PUBLIC_IP}${BARE_REPO}"
echo "  git push production ${GIT_BRANCH}"
echo
echo "Worker bootstrap (pull from main git):"
echo "  git clone ssh://root@${PUBLIC_IP}${BARE_REPO} /opt/messenger/project"
echo "  cd /opt/messenger/project && ./scripts/bootstrap-worker.sh"
else
echo "Git: use GitHub (or your --git URL) on all nodes; workers run install-node.sh --role worker"
fi
echo
echo "Start / update:"
echo "  ./scripts/node-update.sh"
echo
echo "Optional — Gitea UI + auto-deploy on git push:"
echo "  sudo ./scripts/setup-gitea.sh"
echo "  (see docs/DEPLOY-PRODUCTION.md)"
echo
read -rp "Run node-update now? [Y/n] " RUN
if [[ "${NONINTERACTIVE:-}" == "1" ]]; then
  RUN="${RUN_NODE_UPDATE:-Y}"
fi
if [[ "${RUN:-Y}" =~ ^[Yy]$ ]]; then
  "$SCRIPT_DIR/node-update.sh"
fi
