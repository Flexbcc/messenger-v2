# backend `personal_pc` — сигнатура для media-node

Реализация storage-app со стороны ноды: ещё один `BlobBackend` рядом с
`local`/`s3`. Файл: `backend/services/media-node/app/backends/personal_pc.py`.
Подключён в `factory.py` (`personal_backend_for_user`).

## Контракт (как у local/s3)
```
class BlobBackend(Protocol):
    name: str
    def put(key: str, data: bytes) -> None
    def get(key: str) -> Optional[bytes]
    def delete(key: str) -> None
    def exists(key: str) -> bool
```
`PersonalPCBackend.name = "personal_pc"`.

## Маппинг операций (backend → протокол storage-app, SPEC §5)
| BlobBackend | op    | Возврат/ошибка |
|-------------|-------|----------------|
| `put`       | PUT   | ok → None; `quota_exceeded` → `PersonalPCQuotaExceeded`; недоступен → `PersonalPCUnavailable` |
| `get`       | GET   | `not_found` → None; ok → bytes (сверка хэша); иначе исключение |
| `delete`    | DELETE| ok / not_found → None (идемпотентно) |
| `exists`    | STAT  | ok → True; not_found → False |
| `usage()`   | USAGE | объём/файлы/квота (сверх контракта, для статуса) |
| `ping()`    | PING  | bool health без исключений |

## Исключения
`PersonalPCUnavailable` (ПК оффлайн/диск отключён/relay недоступен),
`PersonalPCQuotaExceeded` (PUT сверх квоты → нода делает fallback на primary/S3),
`PersonalPCAuthError` (не сопряжены / ключ отозван),
`PersonalPCIntegrityError` (хэш содержимого не совпал с key).

Синхронный контракт не может вернуть «переполнено» кодом → сигналим исключением;
решение о fallback принимает `media.py` (SETTINGS.md §7 «reject»).

## Конфиг (storage.json → personal_cloud.users[user_id])
```jsonc
"USER_UUID": {
  "backend": "personal_pc",
  "personal_pc": {
    "peer_pubkey": "ed25519:BASE64_PK_STORAGE",
    "relay_url":   "https://relay.example-network.org",
    "lan_hint":    "storage-app.local:7345",
    "quota_bytes": 0
  }
}
```
Пример-контракт: `backend/config/storage.examples/personal-pc.user.example.jsonc`.

## Аутентификация
- Нода подписывает запросы своим Ed25519 (`NODE_SIGNING_KEY_PATH`), ключ должен
  быть сопряжён с storage-app (PAIRING.md).
- `user_id` неймспейсит удалённое хранилище (папка на пользователя на ПК).
- `peer_pubkey` — публичный ключ storage-app, проверяется при установке канала.

## Статус реализации
Реализовано (media-node, `personal_pc.py`):
- `build_default_transport()` — **LAN-direct** HTTP-транспорт по WIRE.md:
  база из `lan_hint` (порт по умолч. 7345, http/https), Ed25519-подпись
  каждого запроса (canonical `METHOD\nPATH\ntimestamp\nhex(sha256(body))`,
  заголовки `X-PPC-Node-Id/Pubkey/Timestamp/Signature`), маппинг статусов
  `401/413/422/404/5xx` → исключения. Ключ ноды — PyNaCl (`nacl.signing`),
  формат seed совместим с `shared/security/keys.py`.
- `PersonalPCBackend._verify_integrity()` — сверка `sha256(data) == key`,
  иначе `PersonalPCIntegrityError`.
- `usage()` — парсинг USAGE-ответа в `PersonalPCUsage`.

Осталось (фаза 2, WIRE.md «Вне охвата»):
- **relay-fallback** через `relay_url` (тот же HTTP, туннелированный через relay) —
  сейчас `build_default_transport` без `lan_hint` бросает `NotImplementedError`.
- mDNS-обнаружение, чанкинг больших блобов, `/ppc/pair` со стороны ноды.
