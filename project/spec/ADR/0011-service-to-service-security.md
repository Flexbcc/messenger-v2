# 0011. Service-to-Service Federation Security

## Статус
Accepted

## Дата
2026-07-06

## Контекст
После Control Plane (ADR-0009) и Gateway mTLS (ADR-0010) data plane остаётся
открытым: `POST /internal/deliver`, `POST /relay/forward`, `POST /buffer` и
др. не требуют аутентификации. Любой в сети может подделать доставку или
прочитать offline buffer.

E2EE ciphertext на сервере не расшифровывается — защищаем **маршрутизацию и
доступ к blob/buffer**, не содержимое сообщений.

## Решение

### Режим `INTERNAL_SECURITY_MODE`

| Режим | Поведение |
|-------|-----------|
| `legacy` (default) | Без проверки — обратная совместимость |
| `signed` | Обязательные federation headers + Ed25519 подпись |

### Federation request headers

- `X-Federation-Node-Id`
- `X-Federation-Timestamp` (ISO UTC)
- `X-Federation-Nonce` (UUID)
- `X-Federation-Signature` (base64 Ed25519)

Подписывается canonical string:

```
{node_id}|{timestamp}|{nonce}|{METHOD}|{path}|{sha256(body)}
```

### Node signing keys

- Каждая нода хранит Ed25519 private key (`NODE_SIGNING_KEY_PATH`)
- Public key публикуется в Discovery (`signing_public_key`) при register
- Получатель кэширует trusted keys из Discovery (TTL 60s)

### Replay protection

Таблица `used_nonces` на принимающей ноде:
`nonce`, `origin_node_id`, `expires_at`

### Capability policy

| Endpoint | Разрешённые capabilities |
|----------|-------------------------|
| `POST /internal/deliver` | home, relay |
| `POST /relay/forward` | home, relay |
| `POST /buffer` | home, relay |
| `GET/DELETE /buffer/*` | home |
| `POST /media` | home |
| `GET /media/*` | home |

### Media access (P5)

| Режим | GET /media/{id} | POST /media |
|-------|-----------------|-------------|
| `legacy` | open | open |
| `signed` | federation / JWT / access_token | federation / JWT |

Home-node проксирует `GET /media/{id}` с JWT; выдаёт signed URL через `/media/{id}/access-url`.

### TURN (P6)

| Режим | POST /turn/credentials |
|-------|------------------------|
| `legacy` | open (dev) |
| `signed` | device JWT required |

### PreKeys (P7)

`PREKEY_CONSUMPTION_MODE=legacy|strict` — strict отдаёт один OTP prekey за запрос.

### FederationEnvelope (Phase B / P2)

Отдельный флаг `FEDERATION_ENVELOPE_MODE=legacy|signed`. В `signed` каждый
межнодовой payload содержит блок `federation` с metadata + Ed25519 подписью
над canonical JSON (без поля `signature`):

```json
{
  "federation": {
    "packet_id": "...",
    "origin_node_id": "home-1",
    "ciphertext_hash": "sha256...",
    "nonce": "uuid",
    "expires_at": "...",
    "signature": "..."
  },
  "envelope": { "...": "client ciphertext unchanged" },
  "conversation_meta": { "..." }
}
```

- Relay проверяет подпись, но **не** потребляет envelope-nonce (`consume_nonce=false`)
- Home/storage — финальная проверка + replay protection
- Audit log: `federation_audit` SQLite, без plaintext

### Что не меняется

- Формат `envelope` / `ciphertext` клиента
- E2EE протокол
- Публичные client API (auth JWT)

## Связанные документы

- [ADR-0009](0009-node-enrollment.md)
- [ADR-0010](0010-node-attestation-and-gateway.md)
- [architecture-network.md](../architecture-network.md)
