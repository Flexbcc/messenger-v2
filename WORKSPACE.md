# Разбиение на самостоятельные проекты

> **Актуальная документация по модулям:** [`docs/README.md`](docs/README.md)  
> У каждого модуля: `docs/modules/<имя>/README.md` + `CHANGELOG.md`

Проект разрезан на независимые папки, чтобы не грузить в контекст весь репозиторий.
Каждая папка самодостаточна и имеет свой README. Оригинал `project/` не тронут.

| Папка          | Что это | Порт/стек |
|----------------|---------|-----------|
| `frontend/`    | Flutter-клиент (UI, E2EE) | Dart/Flutter |
| `backend/`     | Полный бекенд сети проекта — все ноды + admin/operator | Python/FastAPI, все ноды |
| `client-node/` | Упрощённая клиентская нода (home+storage+relay), подключается к сети | Python/FastAPI, :8001 |
| `storage-app/` | Личное хранилище на ПК (headless-сервер + спека UI) | Dart (headless), Flutter UI — позже |
| `simulation/`  | Симуляция сети из множества нод | скелет (движок TODO) |

## backend vs client-node
Одна кодовая база, разная роль:
- **backend** — вся сеть целиком, включая discovery-ROOT, gateway, turn, media, панели.
- **client-node** — то, что хостит сам пользователь: своя home-нода + буфер + микрохаб.
  Находит общую сеть через внешний `DISCOVERY_NODE_URL`, регистрируется, шлёт
  heartbeat (исходящие). Обновления — `slim-update.sh`. Проще в конфиге.

## Аудит документация↔код
См. `AUDIT.md` (сверка 2026-07-14, доки обновлены). Кратко:
- **backend** ~80% реально; спека admin-settings синхронизирована с кодом;
- **frontend** — каталог 184/184 в UI, ~15–25 влияют на поведение (legacy-экраны);
- **client-node** — ядро работает, 14/29 настроек planned; setup/install не для slim;
- **storage-app** — headless-сервер есть; **simulation** — скелет.

## Карта настроек по проектам
Три машиночитаемых каталога настроек (общий формат `meta` + `sections[].settings[]`):
- клиент — `ouo-settings-web-spec/ouo-settings-spec.json` (18 секций / 184);
- нода — `client-node/node-settings-spec.json` (6 / 29, с привязкой `env`);
- админ-бэкенд — `backend/admin-settings-spec.json` (6 / 21, с привязкой `env`).

| Проект | Документ настроек | Что покрывает |
|--------|-------------------|---------------|
| frontend | `frontend/docs/SETTINGS.md` | все пользовательские настройки (спека целиком) |
| client-node | `client-node/docs/SETTINGS.md` | что настраивается на ноде (env, assistance, capacity, обновления) |
| backend | `backend/docs/SETTINGS.md` | discovery/реестр, статус/доступность нод, enrollment, издание обновлений, реакция на уязвимости |
| storage-app | `storage-app/docs/SETTINGS.md` | локальное хранилище на ПК (место/структура/квоты/at-rest) |
| simulation | `simulation/docs/SETTINGS.md` | входные настройки прогона + параметры стенда |

Кросс-проектные секции спеки (`node`, `storage_ownership`, `backup`) живут в UI
клиента, но исполняются нодой/хранилищем — границы описаны в каждом документе.

## Источник и метод
Скопировано из `project/` (см. `SUMMARY.md`). Исключены `.venv`, `__pycache__`,
`*.db`, Flutter `build/`/Pods. Правки в новых папках оригинала не задевают.
