FROM python:3.11-slim

WORKDIR /app

COPY services/gateway-node/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY shared /app/shared
COPY services/gateway-node/app ./app
# A clean source checkout intentionally has no generated release artifacts.
# Ship a safe, empty manifest so the node image remains reproducible; release
# deployments can override RELEASES_MANIFEST with their signed/published file.
COPY services/gateway-node/default-release-manifest.json /app/releases/clients/manifest.json
COPY services/gateway-node/entrypoint.sh ./entrypoint.sh
RUN chmod +x ./entrypoint.sh

ENV PYTHONPATH=/app
ENV PYTHONUNBUFFERED=1
EXPOSE 8007 8447

ENTRYPOINT ["./entrypoint.sh"]
