# frontend — Flutter-клиент

## Назначение

UI мессенджера: чаты, E2EE, Private Mode, каталог настроек. Подключается к Home/Media/Discovery по URL.

## Папка в репозитории

`frontend/` (приложение в `frontend/app/`)

## Статус

**Активный.** Web-first; mobile/desktop — в планах.

## Что входит

| Компонент | Путь | Роль |
|-----------|------|------|
| Flutter app | `app/lib/` | Экраны, state, crypto, API |
| Тесты | `app/test/` | crypto, integration, catalog |
| Доки настроек | `docs/SETTINGS.md` | Покрытие каталога 184 настроек |
| Спека (источник каталога) | `../ouo-settings-web-spec/` | JSON + web-прототип |

## Что НЕ входит

- Бекенд-ноды (см. `backend/`)
- Сборка Docker для нод
- Runtime-чтение всего каталога настроек (часть — placeholder UI)

## Запуск

```bash
cd frontend/app
flutter pub get
flutter test
flutter run -d chrome
```

С `--dart-define=HOME_NODE_URL=...` при необходимости (см. `scripts/run-web.sh`).

## Порты (куда ходит клиент)

| Сервис | Порт по умолчанию |
|--------|-------------------|
| Home Node | 8001 |
| Media Node | 8004 |
| Discovery | 8003 |
| Gateway | 8007 |

## Зависимости

- **backend** или **project** — поднятые ноды
- **ouo-settings-web-spec** — структура каталога (не runtime-зависимость)

## Источник

Скопировано из `project/client/messenger_app/`. Оригинал в `project/` не обязателен для работы над `frontend/`.

## Версии

[CHANGELOG.md](CHANGELOG.md)
