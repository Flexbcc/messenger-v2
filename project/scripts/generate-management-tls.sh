#!/usr/bin/env bash
set -euo pipefail

# Local/private TLS identity for the headless management listener.
# The mobile app pins the leaf certificate fingerprint carried in the QR.

HOST="${1:-localhost}"
OUTPUT="${MANAGEMENT_TLS_OUTPUT:-data/management-tls}"

if [[ "$OUTPUT" != /* ]]; then
  OUTPUT="$(pwd)/$OUTPUT"
fi
mkdir -p "$OUTPUT"
chmod 700 "$OUTPUT"

if [[ -e "$OUTPUT/server.key" || -e "$OUTPUT/server.crt" ]]; then
  echo "Management TLS files already exist at $OUTPUT" >&2
  echo "Remove or archive them explicitly before rotating the identity." >&2
  exit 1
fi

if [[ "$HOST" =~ ^[0-9a-fA-F:.]+$ ]]; then
  SAN="IP:${HOST}"
else
  SAN="DNS:${HOST}"
fi

openssl req -x509 -newkey rsa:3072 -sha256 -nodes -days 397 \
  -keyout "$OUTPUT/server.key" \
  -out "$OUTPUT/server.crt" \
  -subj "/O=OUO Node Owner Management/CN=${HOST}" \
  -addext "subjectAltName=${SAN}" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature,keyEncipherment" \
  -addext "extendedKeyUsage=serverAuth"

chmod 600 "$OUTPUT/server.key"
chmod 644 "$OUTPUT/server.crt"

FINGERPRINT="$(openssl x509 -in "$OUTPUT/server.crt" -outform DER | openssl dgst -sha256 -r | awk '{print $1}')"
printf 'sha256:%s\n' "$FINGERPRINT" > "$OUTPUT/fingerprint.txt"
chmod 644 "$OUTPUT/fingerprint.txt"

echo "Management TLS certificate created"
echo "Host: $HOST"
echo "Fingerprint: sha256:$FINGERPRINT"
echo "Directory: $OUTPUT"
