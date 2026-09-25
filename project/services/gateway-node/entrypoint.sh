#!/bin/sh
set -e
PORT="${PORT:-8007}"

if [ "${GATEWAY_TLS_ENABLED}" = "true" ]; then
  TLS_PORT="${GATEWAY_TLS_PORT:-8447}"
  echo "Starting Gateway with mTLS on :${TLS_PORT}"
  exec uvicorn app.main:app \
    --host 0.0.0.0 \
    --port "${TLS_PORT}" \
    --ssl-keyfile "${GATEWAY_TLS_KEY_PATH}" \
    --ssl-certfile "${GATEWAY_TLS_CERT_PATH}" \
    --ssl-ca-certs "${GATEWAY_TLS_CLIENT_CA_PATH}" \
    --ssl-cert-reqs 2
fi

echo "Starting Gateway (plain HTTP) on :${PORT}"
exec uvicorn app.main:app --host 0.0.0.0 --port "${PORT}"
