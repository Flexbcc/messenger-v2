#!/usr/bin/env bash
set -euo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"

echo "==> Gitea flex/messenger-v2"
export GIT_SSH_COMMAND='ssh -i ~/.ssh/id_ed25519 -o IdentitiesOnly=yes -o ConnectTimeout=20 -p 2222'
git push origin main

echo "==> GitHub Flexbcc/messenger-v2"
export GIT_SSH_COMMAND='ssh -i ~/.ssh/github_messenger_v2 -o IdentitiesOnly=yes -o ConnectTimeout=20'
git push -u github main

echo "Gitea:  http://194.67.92.147:3000/flex/messenger-v2"
echo "GitHub: https://github.com/Flexbcc/messenger-v2"
