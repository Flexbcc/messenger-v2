#!/usr/bin/env bash
# Register one or more deploy keys in Gitea via API.
# Usage:
#   GITEA_PASSWORD=... ./scripts/register-gitea-deploy-keys.sh main "$MAIN_PUB" worker "$WORKER_PUB"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/deploy-common.sh
source "$SCRIPT_DIR/lib/deploy-common.sh"
# shellcheck source=lib/gitea-api.sh
source "$SCRIPT_DIR/lib/gitea-api.sh"

deploy_cd_root
gitea_load_credentials || { echo "GITEA_PASSWORD required" >&2; exit 1; }

while [[ $# -ge 2 ]]; do
  title="$1"
  pubkey="$2"
  shift 2
  gitea_register_deploy_key "$title" "$pubkey" true
done
