#!/usr/bin/env bash
# Push messenger-v2 to Gitea (create empty repo flex/messenger-v2 in UI first).
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT="$(pwd)"
# if invoked from messenger-v2/scripts
if [[ -f "$ROOT/README.md" && -d "$ROOT/.git" ]]; then
  :
elif [[ -d /Users/apple/messenger-v2/.git ]]; then
  cd /Users/apple/messenger-v2
fi

REMOTE="${GITEA_REMOTE:-ssh://git@194.67.92.147:2222/flex/messenger-v2.git}"
KEY="${MESSENGER_OPS_KEY:-$HOME/.ssh/messenger_ops}"

git remote remove origin 2>/dev/null || true
git remote add origin "$REMOTE"

export GIT_SSH_COMMAND="ssh -i ${KEY} -o IdentitiesOnly=yes -o ConnectTimeout=15 -p 2222"
echo "Pushing $(git rev-parse --short HEAD) → $REMOTE"
git push -u origin main
echo "OK. Open http://194.67.92.147:3000/flex/messenger-v2"
