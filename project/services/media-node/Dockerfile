FROM python:3.11-slim

WORKDIR /app

COPY services/media-node/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY shared /app/shared
COPY services/media-node/app ./app

ENV PYTHONPATH=/app
ENV PYTHONUNBUFFERED=1
EXPOSE 8004

CMD ["sh", "-c", "uvicorn app.main:app --host 0.0.0.0 --port ${PORT:-8004}"]
