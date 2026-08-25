FROM python:3.11-slim

WORKDIR /app

COPY services/relay-node/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY shared /app/shared
COPY services/relay-node/app ./app

ENV PYTHONPATH=/app
ENV PYTHONUNBUFFERED=1
EXPOSE 8005/tcp
EXPOSE 8005/udp

CMD ["sh", "-c", "if [ \"${RELAY_QUIC_ENABLED:-false}\" = true ]; then test -n \"${RELAY_TLS_CERT_FILE:-}\" && test -n \"${RELAY_TLS_KEY_FILE:-}\" || exit 64; exec hypercorn --bind 0.0.0.0:${PORT:-8005} --quic-bind 0.0.0.0:${PORT:-8005} --certfile \"${RELAY_TLS_CERT_FILE}\" --keyfile \"${RELAY_TLS_KEY_FILE}\" app.main:app; else exec uvicorn app.main:app --host 0.0.0.0 --port ${PORT:-8005} --ws-max-size ${RELAY_WS_MAX_FRAME_BYTES:-1048576}; fi"]
