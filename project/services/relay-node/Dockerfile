FROM python:3.11-slim

WORKDIR /app

COPY services/relay-node/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY shared /app/shared
COPY services/relay-node/app ./app

ENV PYTHONPATH=/app
ENV PYTHONUNBUFFERED=1
EXPOSE 8005

CMD ["sh", "-c", "uvicorn app.main:app --host 0.0.0.0 --port ${PORT:-8005} --ws-max-size ${RELAY_WS_MAX_FRAME_BYTES:-1048576}"]
