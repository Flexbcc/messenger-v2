# storage-app — личное хранилище на ПК (альтернатива S3)

Отдельный проект. Даёт пользователю альтернативу облачному S3: вместо облака —
**домашний ПК** как место хранения файлов, проходящих через ноду.

Flutter desktop-приложение (Windows / macOS / Linux).

## Идея
1. Пользователь ставит приложение на домашний ПК.
2. При установке указывает **папку**, разрешённую под хранение.
3. Коннектит **ноду ↔ хранилище** простыми действиями (обмен ключами / QR / код).
4. После пары нода складывает все проходящие через неё блобы на этот ПК.
5. Если своей ноды нет — телефон клиента ↔ storage-app **напрямую через общую сеть**.

Файлы приходят уже как **E2EE-шифротекст** — ПК видит только шифр (zero-knowledge).

## Протокол
Свой лёгкий протокол по ключам (**Ed25519 pairing → put/get/delete/stat**),
а не S3. Со стороны ноды — новый storage-backend `personal_pc` в media-node
(рядом с `local`/`s3`). Детали: [`docs/SPEC.md`](docs/SPEC.md),
pairing: [`docs/PAIRING.md`](docs/PAIRING.md).

## Связность (оба режима)
- **LAN-direct** — когда ПК и клиент в одной сети (mDNS/прямой адрес).
- **Relay-fallback** — когда клиент извне: storage-app держит канал к relay/turn
  общей сети (как обычный клиент), NAT не мешает.
См. [`docs/SPEC.md`](docs/SPEC.md) §Транспорт.

## Структура
    app/                 — приложение (сейчас headless CLI; Flutter UI — позже)
      lib/ui/            — экраны: onboarding, выбор папки, пары, статус, логи
      lib/pairing/       — генерация/обмен ключей, коды сопряжения
      lib/storage/       — запись/чтение блобов в разрешённой папке, квоты, GC
      lib/transport/     — put/get/delete/stat поверх ключей
      lib/net/           — LAN (mDNS) + relay/turn коннектор
      lib/models/        — Peer, Blob, StorageConfig, Quota
    docs/
      SPEC.md            — техническая спецификация
      PAIRING.md         — протокол сопряжения нода↔хранилище / телефон↔хранилище
      NOTES.md           — открытые вопросы / доп. настройки (позже)

## Связи с основным проектом
- Новый backend `personal_pc` в `../backend/services/media-node/app/backends/`.
- Профиль конфига: `../backend/config/storage.examples` (добавить `personal-pc`).
- Транспорт опирается на relay/turn из `../backend/services/{relay,turn}-node`.

## Статус (аудит 2026-07-14)
🚧 **Частичная реализация** — headless HTTP-сервер + **Flutter desktop UI**:
онбординг, pairing-код + QR, tray, настройки (порт/папка), revoke пиров.
mDNS/relay, шифрование meta.db, audit/GC — ещё нет.

### Запуск UI (desktop)
```bash
cd app && flutter run -d macos   # или windows / linux
```

### Запуск headless (без UI)
```bash
cd app && dart run lib/headless_main.dart   # env: PPC_ROOT, PPC_PORT
```
См. [`docs/SPEC.md`](docs/SPEC.md), [`docs/WIRE.md`](docs/WIRE.md).

## Dev tools

Ручной E2E smoke для pairing без owner panel: [`tools/ppc_pair_smoke.py`](tools/ppc_pair_smoke.py).
Передайте JSON из QR storage-app (`--payload`), `--user-id` и `--signing-key` ноды — скрипт вызовет `pair_from_qr_payload` и напечатает JSON профиля или ошибку.

После pairing — smoke PUT/GET блоба через `PersonalPCBackend`: [`tools/ppc_blob_smoke.py`](tools/ppc_blob_smoke.py).
Укажите `--user-id`, `--signing-key` и `--lan-hint` (или `--relay-url` + `--storage-node-id`); скрипт положит тестовый блоб и проверит round-trip.
