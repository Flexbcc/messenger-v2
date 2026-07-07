#!/usr/bin/env bash
# Local Operator Console (super-admin for Mac) — http://127.0.0.1:9300
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ ! -f config/deploy/laptop.env ]]; then
  echo "Copy config/deploy/laptop.env.example → laptop.env and set GITEA_PASSWORD + hosts." >&2
  exit 1
fi

chmod +x scripts/operator-console.py
exec python3 scripts/operator-console.py
