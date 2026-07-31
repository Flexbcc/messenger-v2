# personal_pc — wire-протокол (контракт по проводу)

Единый контракт между **нодой** (media-node backend `personal_pc`, Python) и
**storage-app** (сервер на ПК, Dart). Обе стороны реализуют РОВНО это. Фиксирует
формат так, чтобы концы не разошлись. Дополняет SPEC.md/PAIRING.md.
QR payload v2 и маршруты сопряжения: [`PAIRING-FLOWS.md`](PAIRING-FLOWS.md).

## Транспорт
- **HTTP/1.1 + JSON** (тело блобов — сырые байты). Работает и по LAN-direct, и
  позже через relay (relay-fallback — фаза 2, здесь описан LAN-direct как база).
- База: `http(s)://<host>:<port>` из `lan_hint` (по умолчанию порт **7345**).
- Все ответы об ошибках: `{"error": "<code>", "detail": "<msg>"}`.

## Аутентификация (каждый запрос)
Нода подписывает запрос своим Ed25519-ключом (`NODE_SIGNING_KEY_PATH`).
Заголовки:
- `X-PPC-Node-Id` — id ноды;
- `X-PPC-Pubkey` — `ed25519:<base64>` публичный ключ ноды (пира);
- `X-PPC-Timestamp` — unix-время (сек), окно ±300с;
- `X-PPC-Signature` — `base64(Ed25519_sign(canonical))`.

**Canonical string** (подписывается):
```
<METHOD>\n<PATH>\n<X-PPC-Timestamp>\n<hex(sha256(body))>
```
`body` пустой → sha256 пустой строки. storage-app проверяет: подпись валидна,
`X-PPC-Pubkey` есть в `paired_peers`, timestamp в окне. Иначе → `401 unauthorized`.

## Адресация блобов
`hash` = hex SHA-256 шифротекста (контентная адресация). storage-app ОБЯЗАН
проверять, что sha256(тела) == hash в пути (иначе `422 integrity`).
`user_id` неймспейсит хранилище (папка на пользователя).

## Эндпоинты
| Метод | Путь | Тело | Успех | Ошибки |
|-------|------|------|-------|--------|
| GET | `/ppc/health` | — | `200 {"status":"ok","version":"..."}` | — |
| GET | `/ppc/usage?user_id=U` | — | `200 {"used_bytes":N,"used_files":N,"quota_bytes":N}` | 401 |
| PUT | `/ppc/blob/{user_id}/{hash}` | ciphertext (bytes) | `200 {"ok":true,"size":N}` | 401, `413 quota_exceeded`, `422 integrity` |
| GET | `/ppc/blob/{user_id}/{hash}` | — | `200` bytes (`application/octet-stream`, стрим с диска, `Content-Length`); опционально `Range: bytes=start-end` → `206 Partial Content` + `Content-Range` | 401, `404 not_found`, `416` (невалидный Range) |
| DELETE | `/ppc/blob/{user_id}/{hash}` | — | `200 {"ok":true}` | 401 (404 → тоже `200`, идемпотентно) |
| GET | `/ppc/stat/{user_id}/{hash}` | — | `200 {"exists":true,"size":N}` | 401, `404 not_found` |

`quota_bytes: 0` = без лимита. PUT одинакового hash идемпотентен (не перезаписывает).

## Сопряжение (pairing)
| Метод | Путь | Тело | Ответ |
|-------|------|------|-------|
| POST | `/ppc/pair` | `{"code":"123456","peer_pubkey":"ed25519:..","node_id":"..","name":".."}` | `200 {"storage_pubkey":"ed25519:.."}` или `403 bad_code` |

- `code` — короткоживущий (TTL 5 мин), одноразовый, показывается в UI storage-app.
- Успех → storage-app пишет `peer_pubkey` в `paired_peers`, возвращает свой ключ.
- Запрос `/ppc/pair` НЕ требует подписи (пир ещё не сопряжён), но защищён `code`.

## QR / JSON payload (UI)
Актуальная схема — **payload v2** в [`PAIRING-FLOWS.md`](PAIRING-FLOWS.md) §2.
Legacy v1 (LAN-only, без `intent`/`reach`):
```json
{"v":1,"kind":"ouo_ppc_pair","code":"123456","storage_pubkey":"ed25519:..",
 "fingerprint":"aa:bb:..","port":7345,"lan":["192.168.1.10"],"expires_at":1234567890}
```
Инициатор парсит payload, разрешает маршрут (LAN → mDNS → relay) и вызывает
`POST /ppc/pair` с полями из JSON.

## Revoke (отзыв pairing)
| Метод | Путь | Тело | Ответ |
|-------|------|------|-------|
| POST | `/ppc/revoke` | — (пустое) | `200 {"ok":true,"revoked":"<node_id>"}` |

- Требует подписи (как остальные защищённые эндпоинты). `node_id` берётся из
  `X-PPC-Node-Id` — пир отзывает **сам себя**.
- Локальный UI storage-app может отозвать любого пира напрямую (без HTTP).
- Опция «удалить блобы» — wipe `users/<node_id>/` на диске (PAIRING.md).

## Статусы → исключения ноды (personal_pc.py)
`401`→`PersonalPCAuthError`, `413`→`PersonalPCQuotaExceeded`,
`422`→`PersonalPCIntegrityError`, connect/timeout→`PersonalPCUnavailable`,
`404` на GET/STAT → `None`/`False` (не ошибка).

## Вне охвата (фаза 2)
Relay-fallback (тот же HTTP, но туннелированный через relay сети), чанкинг
больших блобов. **mDNS** — реализован в storage-app UI (`_ouo-ppc._tcp`, TXT `fp`/`pk`).
LAN-direct по `lan_hint` остаётся базой для ноды.
