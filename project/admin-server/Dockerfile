FROM python:3.11-slim

WORKDIR /app

# openssh-client — SSH-канал пульта: деплой, рестарт контейнеров, логи.
# В режиме «на сервере» не используется, но образ общий.
RUN apt-get update \
    && apt-get install -y --no-install-recommends openssh-client \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Optional: compose control when /var/run/docker.sock is mounted
RUN mkdir -p /usr/local/lib/docker/cli-plugins
COPY --from=docker:24-cli /usr/local/bin/docker /usr/local/bin/docker
COPY --from=docker:24-cli /usr/local/libexec/docker/cli-plugins/docker-compose /usr/local/lib/docker/cli-plugins/docker-compose

COPY app ./app

ENV PYTHONUNBUFFERED=1
ENV PROJECT_ROOT=/project
ENV ADMIN_STATIC=/project/admin
ENV ENV_FILE=/project/.env
ENV STORAGE_CONFIG=/project/config/storage.json

EXPOSE 9200

CMD ["sh", "-c", "uvicorn app.main:app --host 0.0.0.0 --port ${ADMIN_PORT:-9200}"]
