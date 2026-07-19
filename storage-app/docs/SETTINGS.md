# storage-app — настройки (решённые)

> **Статус реализации (2026-07-17):** headless-сервер + Flutter UI: онбординг,
> pairing (код + QR JSON), tray, settings (порт/папка), revoke пиров (UI + POST
> /ppc/revoke), refcount+GC MVP (§7). **MVP §3:** meta.db at-rest AES-GCM file
> envelope (`PPC1` format, crash recovery, `flushEncrypt`); Ed25519 seed — OS-keystore.
> **Не реализовано:** mDNS/relay, direct-mode телефон↔ПК, SQLCipher.

Свод согласованных решений по конфигурации. Дополняет [`SPEC.md`](SPEC.md).
Открытое — в [`NOTES.md`](NOTES.md).

## Место в общей модели настроек
- Клиент задаёт **политику хранения** (секция `storage_ownership` в
  `../../ouo-settings-web-spec`): `storage.message_location`, `media_location`,
  `replication_factor`, TTL, ключи. storage-app и нода эту политику **исполняют**.
- Концептуальная модель хранилища:
  `../../ouo-settings-web-spec/docs/storage-model.md` (Secure Objects vs User
  Library). storage-app хранит **Secure Objects** (E2EE-блобы).
- Локальные настройки самого приложения на ПК — ниже (не синхронизируются).

## 1. Место хранения
- `allowed_root` выбирается при онбординге (`file_picker`).
- Валидация: доступ на запись, свободное место, предупреждение если внутри
  облачной синхронизации (Dropbox/iCloud/OneDrive).
- Путь в конфиге app. Смена корня → миграция блобов с прогрессом.
- Внешний диск отключён → статус `offline`, ноде ответ `unavailable` (данные целы).
- MVP: один корень. Несколько дисков — бэклог.

## 2. Файловая структура
```
<allowed_root>/
  meta.db                                   # SQLite (plaintext while app runs)
  meta.db.enc                               # encrypted at-rest (see §3)
  .tmp/                                      # незавершённые PUT, atomic rename
  users/<user_uuid>/blobs/<aa>/<bb>/<hash>   # раздельно по пользователям (§5)
```
- Имя файла = хэш шифротекста, без расширения и оригинального имени.
- Шардинг `<aa>/<bb>` по первым байтам хэша.
- Запись строго внутри `allowed_root`; защита от path traversal.

## 3. Шифрование at-rest  →  «блобы как есть + шифр meta.db»
- Блобы приходят уже E2EE-шифротекстом → кладём **как есть**, доп. слой не наводим.
- **`meta.db` шифруется always at-rest** (там хэши/размеры/владельцы): ключ в OS-keystore
  (Keychain / DPAPI / libsecret). ПК никогда не имеет ключей расшифровки контента
  (zero-knowledge сохранён).

### MVP (текущая реализация): AES-GCM file envelope
- Формат `meta.db.enc`: magic `PPC1` ‖ version(1) ‖ nonce(12) ‖ ciphertext ‖ AES-GCM tag(16).
  Старые файлы без magic — legacy `nonce‖cipher‖tag`, читаются при open.
- Целостность: authentication tag AES-GCM (отдельный HMAC не используется).
- Жизненный цикл: `open()` расшифровывает `.enc` → plaintext `meta.db`; `close()` — обратно
  (перед delete plaintext — best-effort overwrite нулями). Пока процесс работает — plaintext
  на диске (WAL `-wal`/`-shm` тоже).
- **Crash recovery:** если после аварии есть и `meta.db`, и `meta.db.enc` — при open выбирается
  валидный SQLite-источник; при обоих валидных — более новый по mtime; stale `.enc`/битый
  plaintext обрабатываются автоматически (см. `MetaDbCrypto.recoverCrashState`).
- **Long-running:** `MetaDb.flushEncrypt()` — checkpoint WAL + атомарная запись `.enc` без
  закрытия БД (plaintext остаётся открыт).

### Headless / CI / tests
- `PPC_INSECURE_KEYS=1` (или `FLUTTER_TEST`): AES-ключ не создаётся, `meta.db` plaintext always,
  Ed25519 seed в `keys.json`. Для headless-сервера без Keychain.

### Будущее (не MVP)
- **SQLCipher** / `sqlcipher_flutter_libs`: page-level шифрование SQLite без plaintext на диске.
  Сейчас не подключено: пакет `sqlite3` без FFI не даёт практично подцепить нативный SQLCipher.
  При появлении нативных сборок — миграция с file-envelope на SQLCipher PRAGMA key.

## 4. Локальная БД  →  SQLite
- Встроенная SQLite (WAL). В БД — только метаданные, содержимое на ФС.
- Отдача по требованию: `hash → путь по шардингу → стрим файла` (без загрузки в RAM).
  HTTP GET поддерживает `Range: bytes=…` → `206 Partial Content` (см. WIRE.md).
- Схема (черновик):
  - `blobs(hash PK, user_uuid, size, created_at, last_access, refcount, state)`
  - `peers(user_uuid PK, pubkey, name, added_at, quota_bytes, revoked)`
  - `audit_log(id, ts, op, user_uuid, hash, size, result)`
  - Индексы: `blobs(last_access)`, `blobs(user_uuid)`.

## 5. Разграничение пользователей  →  «папка на пользователя»
- Каждый пир = `user_uuid` (из pairing). Физически раздельные папки
  `users/<user_uuid>/blobs/...` → изоляция.
- Per-user квоты (`peers.quota_bytes`). `revoke` = удалить папку пользователя.
- Дедупа между пользователями нет (осознанно, ради изоляции).

## 6. Индикация / статусы / логи
- Tray: online/offline, число пиров, занятый объём.
- Экран статуса: свободное место, объём по каждому пиру, вх/исх трафик,
  последняя активность.
- Логи: append-only журнал операций (`audit_log`), ротация, просмотр/экспорт в UI,
  отдельный error-log. В логах — хэши, не содержимое.

## 7. Политики хранения  →  «при переполнении отклонять новые»
- Квоты: глобальная `max_bytes`/`max_files` + per-user `quota_bytes`.
- Переполнение → PUT возвращает `quota_exceeded`; решение о fallback (S3/другой
  бэкенд) принимает **нода**. LRU-вытеснение не делаем (ничего не теряем).
- Удаления инициирует нода (`DELETE` по жизненному циклу сообщений) + refcount-GC.
- **MVP реализовано:** `DELETE` декрементирует `refcount`, при 0 — `pending_delete` +
  удаление файла; `BlobGcRunner` чистит метаданные и осиротевшие файлы по расписанию
  (`PPC_GC_INTERVAL_HOURS`, опц. `PPC_GC_TTL_DAYS` / `PPC_GC_ON_START`).

## Черновик storage-app config
```jsonc
{
  "allowed_root": "/Volumes/Storage/messenger",
  "at_rest": { "blobs": "as_is", "meta_db": "encrypted" },
  "db": "sqlite",
  "isolation": "per_user_folder",
  "quota": { "max_bytes": 0, "max_files": 0, "on_full": "reject" },
  "gc": { "driver": "node", "ttl_days": 0, "schedule_hours": 24 },
  "transport": { "lan": true, "relay_fallback": true }
}
```
(`0` = без лимита.)
