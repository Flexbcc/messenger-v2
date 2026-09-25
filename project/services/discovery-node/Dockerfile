FROM python:3.11-slim

WORKDIR /app

# Контекст сборки — корень project/, а не папка сервиса.
# Иначе не скопировать shared/, который нужен record_signer.py
# (shared.security.keys) и остальным модулям безопасности.
COPY services/discovery-node/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY shared /app/shared
COPY services/discovery-node/app ./app

ENV PYTHONPATH=/app
ENV PYTHONUNBUFFERED=1
EXPOSE 8003

CMD ["sh", "-c", "uvicorn app.main:app --host 0.0.0.0 --port ${PORT:-8003}"]
