# project — dev-стек (оригинал / legacy)

## Назначение

**Исторический монолит** и **активный dev-стек** на машине разработчика: все сервисы, Flutter-клиент внутри, Operator Admin :9201. Отсюда копировали `backend/`, `frontend/`, `client-node/`.

## Папка в репозитории

`project/`

## Статус

**Legacy + активный dev.** Для новой документации предпочтителен `backend/`; для ежедневного docker dev — часто всё ещё `project/`.

## Структура (верхний уровень)

| Путь | Роль |
|------|------|
| `services/` | Те же 7 нод, что в backend |
| `admin/`, `admin-server/` | Operator Admin UI + API |
| `client/messenger_app/` | **Оригинал** Flutter (копия → `frontend/`) |
| `docker-compose.yml` | Полный стек |
| `data/` | Bind-mount БД (discovery, home, …) |
| `config/` | storage.json |
| `spec/`, `docs/` | ADR, HANDOFF |
| `scripts/` | integration-test, deploy |

## Порты (типичный dev)

| Сервис | Порт |
|--------|------|
| home-node | 8001 |
| discovery | 8003 |
| media | 8004 |
| gateway | 8007 |
| **admin** | **9201** |

## Три площадки в одной сети (как у нас настроено)

| Площадка | Путь | Порт | CLUSTER_ID |
|----------|------|------|------------|
| Project dev | `project/` | 8001, admin 9201 | `default` |
| Главная нода | `main-node/` | 9205, /ops | `operator-main` |
| Client test | `client-node/` | 18011 | `client-test` |

## Почему «старое», но не удалено

- Живые `data/discovery/` bind-mounts
- Привычный `docker compose` для полного стека
- Admin static монтируется в `main-node` admin

## Куда переносить работу

| Тип задачи | Куда |
|------------|------|
| Новая фича discovery/admin | `backend/` + синхронизация в `project/` при необходимости |
| Правка home-node panel | `client-node/` + копия в `project/services/home-node/` |
| Только UI клиента | `frontend/` |

## Версии

[CHANGELOG.md](CHANGELOG.md)
