# 0210. Signed NodeAdvertisement v1

## Статус
Implemented locally — issue/verify, secure registration/heartbeat enforcement,
bounded D1/D2/D3 observation gossip и peer-catalog expiry filtering реализованы.

## Назначение
NodeAdvertisement — подписанное самой нодой краткоживущее описание её
достижимых endpoints и поддерживаемых transport/protocol versions. Discovery
только хранит и распространяет объект, но не создаёт его.

Advertisement не содержит самозаявленный список capabilities. Права приходят
отдельным CapabilityCertificate с кворумом.

## Поля
- `protocol_version = ouo-node-advertisement/1`;
- `object_version = 1`;
- `advertisement_id` — UUID;
- `node_id` — self-certifying NodeID;
- `operational_certificate` — root-signed certificate из `0206`;
- `endpoints[]` — не более 16 URL `https`, `wss`, `http`, `ws`;
- `supported_transports[]` — `https`, `wss`, `quic`;
- `supported_protocols[]` — versioned protocol identifiers;
- `epoch` — monotonic advertisement epoch;
- `issued_at`, `expires_at` — срок не более 24 часов и не дольше
  OperationalCertificate;
- `signature` — operational Ed25519 signature.

## Domain separation

```text
"OUO/NODE_ADVERTISEMENT/v1\0" || canonical_json(advertisement_without_signature)
```

## Проверка
1. Exact schema, размеры и версии.
2. OperationalCertificate и self-certifying NodeID.
3. URL/transport/protocol allowlists.
4. Lifetime, expiry и monotonic epoch.
5. Operational signature.
6. CapabilityCertificate проверяется независимо; наличие Advertisement не
   выдаёт Relay/Storage/Discovery права.
7. Две разные подписанные записи одного subject/epoch считаются equivocation;
   повтор идентичной записи идемпотентен.
8. В `enforce` каждый heartbeat обновляет краткоживущий Advertisement. Нода с
   отсутствующим, повреждённым или просроченным Advertisement не проходит
   heartbeat и исключается из обычного node/peer listing даже до offline TTL.

## Не входит
- DNS ownership proof;
- сетевой reachability probe;
- production operator/source diversity;
- RouteDescriptor пользователя.

## Reference implementation
- `shared/security/node_advertisement.py`
- `shared/security/node_advertisement_enrollment.py`
- `services/discovery-node/app/node_advertisement_gossip.py`
- `tests/security/test_node_advertisement.py`
- `tests/security/test_node_advertisement_enrollment.py`
- `tests/integration/test_discovery_node_advertisement_gossip.py`
- `tests/integration/test_discovery_node_identity.py`
