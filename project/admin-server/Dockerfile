FROM python:3.11-slim

WORKDIR /app

COPY admin-server/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY admin-server/app ./app
# Admin reuses the same strict origin validator as the backend services. Keep
# the package marker minimal so importing this one helper does not pull the
# full federation crypto stack into the lightweight console image.
COPY shared ./shared
RUN printf '%s\n' '# Admin image package marker.' > /app/shared/security/__init__.py

ENV PYTHONUNBUFFERED=1
ENV PROJECT_ROOT=/project
ENV ADMIN_STATIC=/project/admin
ENV ENV_FILE=/project/.env
ENV STORAGE_CONFIG=/project/config/storage.json

EXPOSE 9200

CMD ["sh", "-c", "uvicorn app.main:app --host 0.0.0.0 --port ${ADMIN_PORT:-9200}"]
