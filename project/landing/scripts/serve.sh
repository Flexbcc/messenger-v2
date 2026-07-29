#!/usr/bin/env bash
# Local preview: http://localhost:8080
set -euo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$DIR"
if [[ ! -f downloads/Messenger-macos-arm64.zip ]]; then
  echo "Run ./scripts/sync-downloads.sh first" >&2
  exit 1
fi
echo "Landing → http://localhost:8080"
exec python3 -m http.server 8080
