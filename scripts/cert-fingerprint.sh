#!/usr/bin/env bash
# Print sha256 fingerprint (hex, lowercase) for a PEM certificate.
set -euo pipefail
CERT="${1:?usage: cert-fingerprint.sh path/to/cert.pem}"
openssl x509 -in "$CERT" -noout -fingerprint -sha256 \
  | sed 's/sha256 Fingerprint=//I' \
  | tr -d ':' \
  | tr '[:upper:]' '[:lower:]'
