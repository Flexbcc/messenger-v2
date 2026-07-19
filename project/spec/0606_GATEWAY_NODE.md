# 0606. Gateway Node

## Статус
Черновик (MVP реализован)

## Назначение
Публичная точка входа для клиентов: каталог trusted-нод, разрешение
пользователей, bootstrap маршрутизации. Не участвует в доставке
сообщений и не имеет доступа к plaintext (E2EE).

## Capability
`gateway` — публикуется в Discovery Control Plane.

## API (MVP)

| Метод | Путь | Описание |
|-------|------|----------|
| GET | `/health` | Health + load |
| GET | `/gateway/routing` | Client bootstrap: gateways, media, home, discovery URL; `strategy=nearest` для preferred endpoints |
| GET | `/gateway/mtls/info` | Статус mTLS/TLS политики |
| GET | `/gateway/catalog/nodes` | Прокси `GET /registry/nodes` |
| GET | `/gateway/catalog/users/{user_id}` | Прокси resolve user |
| * | `/gateway/proxy/discovery/{path}` | Прокси к Discovery |

## Конфигурация

| Переменная | Назначение |
|------------|------------|
| `GATEWAY_NODE_ID` | node_id в Discovery |
| `GATEWAY_NODE_PUBLIC_URL` | Публичный URL |
| `DISCOVERY_NODE_URL` | Внутренний URL Discovery |
| `GATEWAY_DISCOVERY_PUBLIC_URL` | URL Discovery для клиентов |
| `DEFAULT_HOME_NODE_URL` | Fallback home (single-cluster) |
| `DEFAULT_MEDIA_NODE_URL` | Fallback media |
| `GATEWAY_TLS_ENABLED` | `true` — HTTPS+mTLS на `GATEWAY_TLS_PORT` (8447) |
| `GATEWAY_TLS_*_PATH` | Пути к server key/cert и client CA (`/mtls/...`) |
| `GATEWAY_MTLS_MODE` | `off` \| `optional` \| `required` |
| `ALLOWED_GATEWAY_CLIENT_FINGERPRINTS` | Allowlist SHA256 client cert |

## mTLS (dev)

```bash
./scripts/generate-mtls-certs.sh
# В .env: GATEWAY_TLS_ENABLED=true GATEWAY_MTLS_MODE=required
docker compose up -d gateway-node
curl --cacert config/mtls/ca.crt --cert config/mtls/clients/client-dev.crt \
  --key config/mtls/clients/client-dev.key https://localhost:8447/gateway/routing
```

## Ограничения

- Прокси не проверяет подписи пакетов — это роль Home/Relay.

## Связанные документы

- [ADR-0010](ADR/0010-node-attestation-and-gateway.md)
- [0604_DISCOVERY_NODE.md](0604_DISCOVERY_NODE.md)
