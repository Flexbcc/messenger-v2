#!/usr/bin/env bash
# Push from laptop → Gitea → auto-deploy on main server.
#
# Usage:
#   ./scripts/push-deploy.sh
#   ./scripts/push-deploy.sh --host git@1.2.3.4 --port 2222 --branch main
#
# Requires: git, SSH key added in Gitea (Settings → SSH Keys).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

# shellcheck source=lib/laptop-env.sh
source "$SCRIPT_DIR/lib/laptop-env.sh"
load_laptop_env "$PROJECT_ROOT"

GIT_HOST="${GIT_HOST:-${MAIN_IP:-}}"
GIT_PORT="2222"
GIT_OWNER="flex"
GIT_REPO="messenger"
BRANCH="main"
REMOTE="origin"
MESSAGE=""
NO_PUSH=""

usage() {
  sed -n '2,8p' "$0"
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) GIT_HOST="$2"; shift 2 ;;
    --port) GIT_PORT="$2"; shift 2 ;;
    --owner) GIT_OWNER="$2"; shift 2 ;;
    --repo) GIT_REPO="$2"; shift 2 ;;
    --branch) BRANCH="$2"; shift 2 ;;
    --remote) REMOTE="$2"; shift 2 ;;
    --message|-m) MESSAGE="$2"; shift 2 ;;
    --no-push) NO_PUSH=1; shift ;;
    -h|--help) usage 0 ;;
    *) echo "Unknown: $1" >&2; usage 1 ;;
  esac
done

# Load saved server hints from gitea.env if present locally (optional copy from server).
HINTS="$PROJECT_ROOT/config/deploy/gitea.env"
if [[ -z "$GIT_HOST" && -f "$HINTS" ]]; then
  # shellcheck disable=SC1090
  source "$HINTS"
  if [[ -n "${GITEA_SSH:-}" ]]; then
    REMOTE_URL="$GITEA_SSH"
  fi
fi

if [[ -z "${REMOTE_URL:-}" ]]; then
  [[ -n "$GIT_HOST" ]] || { echo "Set --host SERVER_IP (or git@SERVER) or copy config/deploy/gitea.env from server." >&2; exit 1; }
  # Accept "1.2.3.4", "git@1.2.3.4", or ssh config alias "messenger-git"
  if [[ "$GIT_HOST" == git@* ]]; then
    REMOTE_URL="ssh://${GIT_HOST}:${GIT_PORT}/${GIT_OWNER}/${GIT_REPO}.git"
  else
    REMOTE_URL="ssh://git@${GIT_HOST}:${GIT_PORT}/${GIT_OWNER}/${GIT_REPO}.git"
  fi
fi

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git init
  git checkout -B "$BRANCH"
fi

if ! git remote get-url "$REMOTE" >/dev/null 2>&1; then
  git remote add "$REMOTE" "$REMOTE_URL"
else
  git remote set-url "$REMOTE" "$REMOTE_URL"
fi

git add -A
if git diff --cached --quiet; then
  echo "Nothing to commit."
else
  MSG="${MESSAGE:-update $(date -u +%Y-%m-%dT%H:%M:%SZ)}"
  git commit -m "$MSG"
fi

if [[ -n "$NO_PUSH" ]]; then
  echo "Committed locally (--no-push)."
  exit 0
fi

echo "Pushing to $REMOTE ($BRANCH)..."
git push -u "$REMOTE" "$BRANCH"
echo
echo "Push sent → Gitea webhook → main deploy.sh → workers (automatic)."
echo "  ./scripts/watch-deploy.sh"
echo "  ./scripts/start-operator.sh   # local super-admin UI"
