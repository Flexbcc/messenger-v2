FROM python:3.12-slim

WORKDIR /app

COPY services/push-proxy/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY shared /app/shared
COPY services/push-proxy/app /app/app

ENV PYTHONPATH=/app

EXPOSE 8008

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8008"]
