FROM python:3.12-alpine

WORKDIR /observer
COPY tools/traffic-observer/observer.py /observer/observer.py
COPY tools/traffic-observer/analyze.py /observer/analyze.py

RUN addgroup -S observer && adduser -S -G observer observer \
    && mkdir -p /captures \
    && chown -R observer:observer /observer /captures

USER observer
ENTRYPOINT ["python", "/observer/observer.py"]
CMD ["--config", "/config/listeners.json", "--output", "/captures/traffic.jsonl"]
