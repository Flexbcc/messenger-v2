# 0010. Node Attestation and Gateway Node

## Статус
Accepted

## Дата
2026-07-06

## Контекст
После enrollment (ADR-0009) Control Plane знает, **кому** доверять
(`trust_status`), но не проверяет, **что именно** запущено на ноде.
Для публичной федерации нужны build hash, подписанные релизы и (в
перспективе) mTLS. Клиентам также нужна единая точка входа — Gateway Node.

## Решение (этап 6 — реализовано)

### Attestation на Discovery

| Поле регистрации | Назначение |
|------------------|------------|
| `build_hash` | Идентификатор сборки/образа |
| `tls_cert_fingerprint` | Отпечаток TLS-сертификата (заготовка под mTLS) |
| `release_signature` | Подпись `{node_id}:{build_hash}:{software_version}` (Ed25519 или HMAC) |

| `ATTESTATION_MODE` | Поведение |
|--------------------|-----------|
| `off` (default) | Поля принимаются, проверка не блокирует |
| `report` | Проверка, статус в каталоге, без блокировки |
| `enforce` | Отклонение регистрации/heartbeat при нарушении allowlist/подписи |

Дополнительно: `MTLS_MODE=report|enforce` + `ALLOWED_TLS_CERT_FINGERPRINTS`.

Оператор подписывает релиз: `scripts/sign-node-release.py` →
`NODE_RELEASE_SIGNATURE` на ноде.

- `RELEASE_SIGNING_PUBLIC_KEYS` (рекомендуется): `node_id:base64_verify_key,...`
- `RELEASE_SIGNING_SECRET` (legacy fallback): HMAC-ключ для совместимости

### Gateway Node

Новый сервис `gateway-node` (capability `gateway`):

- `GET /gateway/routing` — bootstrap для клиента (gateways, media, home, discovery URL)
  + `strategy=nearest` возвращает `preferred.*` по минимальной latency `/health`
- `GET /gateway/catalog/nodes` — прокси каталога Discovery (только trusted)
- `GET /gateway/catalog/users/{id}` — разрешение UserID
- `GET /gateway/proxy/discovery/{path}` — прокси к Discovery (CORS workaround)

Gateway **не** расшифровывает сообщения — только маршрутизация и каталог.

### Этап 7 (реализовано) — mTLS на Gateway

- `scripts/generate-mtls-certs.sh` — dev CA, server cert, client certs
- Gateway `entrypoint.sh`: TLS termination (`GATEWAY_TLS_ENABLED=true`, порт 8447)
- Uvicorn `--ssl-cert-reqs 2` — client cert обязателен на TLS-порту
- `GATEWAY_MTLS_MODE=required|optional` — проверка fingerprint заголовка
  `X-Client-Cert-SHA256` на `/gateway/*` (для HTTP-режима и логирования)
- `GET /gateway/mtls/info` — статус политики
- Discovery `MTLS_MODE` + `ALLOWED_TLS_CERT_FINGERPRINTS` для нод

## Не в scope

- Remote attestation (TPM/SGX)
- Полноценный client SDK (Flutter) — nearest routing отдаёт Gateway

## Связанные документы

- [ADR-0009](0009-node-enrollment.md)
- [0606_GATEWAY_NODE.md](../0606_GATEWAY_NODE.md)
