# Network Architecture (Production Target)

## Client traffic (public)

```
Flutter Client
    │
    ├─► Gateway :8447 (mTLS)     bootstrap, catalog, routing
    │
    └─► Home Node :8001 (JWT)    auth, messages, WebSocket, prekeys, media proxy
```

Клиент **не** обращается напрямую к storage, relay, turn internal APIs.

Media в production:
- upload/download через Home (`GET /media/{id}`) или signed URL от Home (`/media/{id}/access-url`)
- прямой `MEDIA_NODE_URL` — только legacy dev

TURN: `POST /turn/credentials` с device JWT (signed mode).

## Service-to-service (private)

```
Home ──signed──► Home     POST /internal/deliver
Home ──signed──► Relay ──► Home
Home ──signed──► Storage   POST/GET/DELETE /buffer
Home ──signed──► Media     GET/POST /media
```

Каждый deliver/buffer payload может включать `federation` блок (Phase B):
`packet_id`, `ciphertext_hash`, `nonce`, `signature` — **без изменения** client `ciphertext`.

- Порты storage/relay **не публикуются** на host в docker-compose (expose only)
- `INTERNAL_SECURITY_MODE=signed` — HTTP federation headers
- `FEDERATION_ENVELOPE_MODE=signed` — подписанная обёртка envelope

## Control Plane (orthogonal)

```
All nodes ──► Discovery   register, heartbeat, enrollment, attestation
Operator  ──► Admin UI    enrollment approve, monitor
```

## Trust axes (ADR-0009)

- `trust_status` — operator approval
- `reachability` — heartbeat liveness
- `signing_public_key` — federation identity (ADR-0011)

## Dev vs prod

| | Dev | Prod |
|---|-----|------|
| INTERNAL_SECURITY_MODE | legacy | signed |
| FEDERATION_ENVELOPE_MODE | legacy | signed |
| PREKEY_CONSUMPTION_MODE | legacy | strict |
| Gateway TLS | optional | required |
| ENROLLMENT_MODE | legacy | strict/hybrid |
| Storage/Relay ports | internal (docker network) | internal only |
| Media/Turn ports | localhost (convenience) | JWT / signed URL |

## Observability

Каждая нода отдаёт `security` блок в `GET /health`:
`invalid_signature`, `replay_rejected`, `rate_limit_hits`, …
