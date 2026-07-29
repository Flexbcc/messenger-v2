#!/usr/bin/env bash
# Push flex/messenger to Gitea (origin) and GitHub mirror (github).
set -euo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"

GITEA_KEY="${MESSENGER_OPS_KEY:-$HOME/.ssh/id_ed25519}"
GITHUB_KEY="${GITHUB_MESSENGER_KEY:-$HOME/.ssh/github_messenger_v2}"

if ! git remote get-url github &>/dev/null; then
  git remote add github git@github.com:Flexbcc/messenger.git
fi

echo "==> Gitea flex/messenger"
export GIT_SSH_COMMAND="ssh -i ${GITEA_KEY} -o IdentitiesOnly=yes -o ConnectTimeout=20 -p 2222"
git push origin main

echo "==> GitHub Flexbcc/messenger"
export GIT_SSH_COMMAND="ssh -i ${GITHUB_KEY} -o IdentitiesOnly=yes -o ConnectTimeout=20"
git push -u github main

echo "Gitea:  http://194.67.92.147:3000/flex/messenger"
echo "GitHub: https://github.com/Flexbcc/messenger"
