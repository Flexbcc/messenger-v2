#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 --inventory FILE --output DIRECTORY" >&2
  exit 64
}

INVENTORY=""
OUTPUT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --inventory) [[ $# -ge 2 ]] || usage; INVENTORY="$2"; shift 2 ;;
    --output) [[ $# -ge 2 ]] || usage; OUTPUT="$2"; shift 2 ;;
    *) usage ;;
  esac
done

[[ -f "$INVENTORY" && -n "$OUTPUT" ]] || usage
[[ ! -e "$OUTPUT" ]] || {
  echo "refusing to overwrite existing PKI directory: $OUTPUT" >&2
  exit 73
}
command -v openssl >/dev/null || { echo "openssl is required" >&2; exit 69; }

PARENT="$(dirname "$OUTPUT")"
mkdir -p "$PARENT"
STAGE="$(mktemp -d "${PARENT}/.quic-pki.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
umask 077
mkdir -p "$STAGE/root" "$STAGE/issuer" "$STAGE/nodes" "$STAGE/trust"

cat >"$STAGE/root/extensions.cnf" <<'EOF'
[req]
prompt = no
distinguished_name = root_dn
x509_extensions = root_ca
[root_dn]
O = OUO Test Network
CN = OUO QUIC Offline Root CA
[root_ca]
basicConstraints = critical,CA:true,pathlen:1
keyUsage = critical,keyCertSign,cRLSign
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always
EOF

openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-384 \
  -out "$STAGE/root/root-ca.key"
openssl req -new -x509 -sha384 -days 3650 \
  -key "$STAGE/root/root-ca.key" \
  -config "$STAGE/root/extensions.cnf" \
  -out "$STAGE/root/root-ca.crt"

cat >"$STAGE/issuer/extensions.cnf" <<'EOF'
[issuing_ca]
basicConstraints = critical,CA:true,pathlen:0
keyUsage = critical,keyCertSign,cRLSign
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always
EOF

openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-384 \
  -out "$STAGE/issuer/quic-issuing-ca.key"
openssl req -new -sha384 -key "$STAGE/issuer/quic-issuing-ca.key" \
  -subj "/O=OUO Test Network/CN=OUO QUIC Issuing CA" \
  -out "$STAGE/issuer/quic-issuing-ca.csr"
openssl rand -hex 16 >"$STAGE/root/root-ca.srl"
openssl x509 -req -sha384 -days 1825 \
  -in "$STAGE/issuer/quic-issuing-ca.csr" \
  -CA "$STAGE/root/root-ca.crt" -CAkey "$STAGE/root/root-ca.key" \
  -CAserial "$STAGE/root/root-ca.srl" -extfile "$STAGE/issuer/extensions.cnf" \
  -extensions issuing_ca -out "$STAGE/issuer/quic-issuing-ca.crt"

cat "$STAGE/issuer/quic-issuing-ca.crt" "$STAGE/root/root-ca.crt" \
  >"$STAGE/trust/ca-chain.crt"
openssl rand -hex 16 >"$STAGE/issuer/quic-issuing-ca.srl"

COUNT=0
while IFS=, read -r NAME DNS_NAMES IP_ADDRESSES; do
  [[ -n "$NAME" && "${NAME:0:1}" != "#" ]] || continue
  [[ "$NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]{0,62}$ ]] || {
    echo "invalid node name: $NAME" >&2; exit 65;
  }
  NODE_DIR="$STAGE/nodes/$NAME"
  mkdir -p "$NODE_DIR"
  openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 \
    -out "$NODE_DIR/tls.key"
  openssl req -new -sha256 -key "$NODE_DIR/tls.key" \
    -subj "/O=OUO Test Network/CN=$NAME" -out "$NODE_DIR/tls.csr"

  {
    echo '[leaf]'
    echo 'basicConstraints = critical,CA:false'
    echo 'keyUsage = critical,digitalSignature'
    echo 'extendedKeyUsage = serverAuth,clientAuth'
    echo 'subjectKeyIdentifier = hash'
    echo 'authorityKeyIdentifier = keyid,issuer'
    echo 'subjectAltName = @alt_names'
    echo '[alt_names]'
    INDEX=1
    IFS=';' read -ra DNS_LIST <<<"$DNS_NAMES"
    for DNS in "${DNS_LIST[@]}"; do
      [[ -n "$DNS" ]] || continue
      [[ "$DNS" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]{0,252}$ ]] || {
        echo "invalid DNS SAN for $NAME: $DNS" >&2; exit 65;
      }
      echo "DNS.$INDEX = $DNS"
      INDEX=$((INDEX + 1))
    done
    INDEX=1
    IFS=';' read -ra IP_LIST <<<"$IP_ADDRESSES"
    for IP in "${IP_LIST[@]}"; do
      [[ -n "$IP" ]] || continue
      echo "IP.$INDEX = $IP"
      INDEX=$((INDEX + 1))
    done
  } >"$NODE_DIR/extensions.cnf"

  openssl x509 -req -sha256 -days 397 -in "$NODE_DIR/tls.csr" \
    -CA "$STAGE/issuer/quic-issuing-ca.crt" \
    -CAkey "$STAGE/issuer/quic-issuing-ca.key" \
    -CAserial "$STAGE/issuer/quic-issuing-ca.srl" \
    -extfile "$NODE_DIR/extensions.cnf" -extensions leaf \
    -out "$NODE_DIR/tls.crt"
  openssl verify -CAfile "$STAGE/root/root-ca.crt" \
    -untrusted "$STAGE/issuer/quic-issuing-ca.crt" "$NODE_DIR/tls.crt" \
    >/dev/null
  cp "$STAGE/trust/ca-chain.crt" "$NODE_DIR/ca-chain.crt"
  openssl x509 -in "$NODE_DIR/tls.crt" -noout -fingerprint -sha256 \
    >"$NODE_DIR/fingerprint.sha256"
  chmod 600 "$NODE_DIR/tls.key"
  chmod 644 "$NODE_DIR/tls.crt" "$NODE_DIR/ca-chain.crt" \
    "$NODE_DIR/fingerprint.sha256"
  COUNT=$((COUNT + 1))
done <"$INVENTORY"

[[ $COUNT -gt 0 ]] || { echo "inventory contains no nodes" >&2; exit 65; }
chmod 600 "$STAGE/root/root-ca.key" "$STAGE/issuer/quic-issuing-ca.key"
chmod 644 "$STAGE/root/root-ca.crt" "$STAGE/issuer/quic-issuing-ca.crt" \
  "$STAGE/trust/ca-chain.crt"
cat >"$STAGE/README.txt" <<EOF
Generated OUO QUIC stand PKI with $COUNT leaf certificates.
Keep root/ and issuer/ offline. Mount only nodes/<name>/ into that node.
Home trust bundle: trust/ca-chain.crt
EOF

mv "$STAGE" "$OUTPUT"
trap - EXIT
echo "generated $COUNT QUIC certificates at $OUTPUT"
