# storage-app — личное хранилище на ПК

## Назначение

Альтернатива S3: **домашний ПК** как хранилище E2EE-блобов (zero-knowledge). Pairing по Ed25519, протокол put/get/delete/stat.

## Папка в репозитории

`storage-app/`

## Статус

**В разработке.** Headless HTTP-сервер + Flutter UI: онбординг, QR pairing,
tray, settings, revoke, audit log, mDNS LAN.

## Что входит

| Компонент | Путь | Роль |
|-----------|------|------|
| Headless server | `app/lib/` | pairing, blob store, quotas |
| Тесты | `app/test/` | ppc_server_test |
| Спека | `docs/SPEC.md`, `PAIRING.md` | протокол, транспорт |

## Что НЕ входит (пока)

- Flutter desktop UI
- mDNS / relay fallback в проде
- encrypted meta.db, audit/GC

## Связь с сетью

Новый backend `personal_pc` в media-node (в backend/project) — **заглушка** на стороне ноды.

## Запуск

```bash
cd storage-app/app && flutter run -d macos   # UI
cd storage-app/app && dart run lib/headless_main.dart   # без UI
```

## Версии

[CHANGELOG.md](CHANGELOG.md)
