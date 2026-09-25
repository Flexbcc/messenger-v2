FROM python:3.11-slim

WORKDIR /app

COPY services/management-node/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY shared /app/shared
COPY services/management-node/app /app/app
COPY scripts/ouoctl.py /app/ouoctl.py

ENV PYTHONPATH=/app
ENV PYTHONUNBUFFERED=1
EXPOSE 9443

CMD ["sh", "-c", "TLS_ARGS=''; if [ -f /tls/server.crt ] && [ -f /tls/server.key ]; then TLS_ARGS='--ssl-certfile /tls/server.crt --ssl-keyfile /tls/server.key'; fi; exec uvicorn app.main:app --host 0.0.0.0 --port ${PORT:-9443} $TLS_ARGS"]
