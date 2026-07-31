#!/usr/bin/env bash
# Compute a reproducible build identifier for node attestation (ADR-0010).
set -euo pipefail

cd "$(dirname "$0")/.."

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  base="$(git rev-parse HEAD)"
  if ! git diff --quiet || ! git diff --cached --quiet; then
    dirty="$(git status --porcelain | shasum -a 256 | awk '{print $1}')"
    printf '%s-%s\n' "$base" "${dirty:0:12}"
  else
    printf '%s\n' "$base"
  fi
  exit 0
fi

find services shared -type f \( -name '*.py' -o -name 'Dockerfile' -o -name 'requirements.txt' \) 2>/dev/null \
  | sort \
  | while read -r f; do shasum -a 256 "$f"; done \
  | shasum -a 256 \
  | awk '{print $1}'
