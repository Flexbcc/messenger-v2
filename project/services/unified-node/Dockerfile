FROM python:3.11-slim

WORKDIR /runtime
COPY services/unified-node/requirements.txt /runtime/requirements.txt
RUN pip install --no-cache-dir -r /runtime/requirements.txt

COPY shared /runtime/shared
COPY services/home-node/app /runtime/modules/home/app
COPY services/discovery-node/app /runtime/modules/discovery/app
COPY services/storage-node/app /runtime/modules/storage/app
COPY services/media-node/app /runtime/modules/media/app
COPY services/relay-node/app /runtime/modules/relay/app
COPY services/unified-node/bootstrap_identity.py /runtime/bootstrap_identity.py
COPY services/unified-node/entrypoint.sh /runtime/entrypoint.sh
RUN chmod 0755 /runtime/entrypoint.sh

ENV PYTHONPATH=/runtime
ENV PYTHONUNBUFFERED=1
EXPOSE 8001 8002 8003 8004 8005
ENTRYPOINT ["/runtime/entrypoint.sh"]
