# 0225 — Federation Admission v1

## Порядок

Signed HTTP/WSS admission выполняет проверки от дешёвых к дорогим:

1. обязательные headers и жёсткие length/type bounds;
2. canonical UUID connection/request nonce;
3. один bounded anonymous token bucket;
4. timestamp parsing и bounded skew;
5. lookup NodeID в single-flight TrustCache;
6. per-trusted-node bounded token bucket;
7. Capability policy;
8. Operational signature;
9. persistent nonce consume/replay check;
10. parsing/processing payload.

Unknown NodeID не создаёт per-identity limiter bucket. Limiter имеет hard maximum
keys и отклоняет новый key при заполнении, а не растит RAM. Пустой Discovery
catalog является валидным negative-cache result на TTL; concurrent callers
делят один refresh.

Relay WSS дополнительно ограничивает global/per-peer connections, frame bytes,
cells/batch, idle, cell processing и send timeout (см. `0214`).

## Остаточные ограничения

Это application-layer admission. Он не спасает физический uplink от volumetric
DDoS. Address validation/reverse proxy limits, adaptive PoW для anonymous
bootstrap и измеримый load test остаются deployment/P1 задачами.
