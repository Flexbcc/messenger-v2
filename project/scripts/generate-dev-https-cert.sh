#!/usr/bin/env bash
# Generate a self-signed TLS cert for local/dev PWA + nginx (WebRTC needs HTTPS except localhost).
#
# Usage:
#   ./scripts/generate-dev-https-cert.sh messenger.local
#   sudo mkdir -p /etc/ssl/messenger
#   sudo cp config/dev-https/fullchain.pem /etc/ssl/messenger/
#   sudo cp config/dev-https/privkey.pem /etc/ssl/messenger/
#
# Trust locally (pick one):
#   mkcert -install   # then re-run with mkcert instead of openssl
#   macOS: add fullchain.pem to Keychain → Always Trust
#
set -euo pipefail

HOST="${1:-messenger.local}"
OUT_DIR="$(cd "$(dirname "$0")/.." && pwd)/config/dev-https"
DAYS=825

mkdir -p "$OUT_DIR"

openssl req -x509 -nodes -newkey rsa:2048 \
  -keyout "$OUT_DIR/privkey.pem" \
  -out "$OUT_DIR/fullchain.pem" \
  -days "$DAYS" \
  -subj "/CN=$HOST" \
  -addext "subjectAltName=DNS:$HOST,DNS:localhost,IP:127.0.0.1"

echo "Wrote:"
echo "  $OUT_DIR/fullchain.pem"
echo "  $OUT_DIR/privkey.pem"
echo ""
echo "Point nginx ssl_certificate / ssl_certificate_key to these files."
echo "Add to /etc/hosts: 127.0.0.1 $HOST"
echo "Open https://$HOST/ and accept the browser warning once."
