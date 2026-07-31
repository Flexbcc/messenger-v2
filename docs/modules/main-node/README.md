# main-node — главная нода оператора

## Назначение

**Личная Home Node оператора** с полной операторской консолью. Отдельный `CLUSTER_ID`, отдельный порт — не путать с dev-стеком `project/` и тестовым `client-node/`.

## Папка в репозитории

`main-node/` — только **compose + .env + data/**; код сервисов **не дублируется** (сборка из `client-node/`).

## Статус

**Активный.**

## Состав docker-compose

| Сервис | Источник сборки | Порт / доступ |
|--------|-----------------|---------------|
| `home-node` | `../client-node` | **9205** → 8001 |
| `storage-node` | `../client-node` | internal |
| `relay-node` | `../client-node` | internal |
| `admin` | `../project/admin-server` | internal :9206, снаружи через `/ops` |

## URL

| URL | Кто |
|-----|-----|
| http://127.0.0.1:9205/panel | Владелец — простой обзор |
| http://127.0.0.1:9205/ops | **Operator Console** — мониторинг, узлы, доверие, настройки |
| http://127.0.0.1:9201 | Dev Admin **project-стека** (весь default cluster) |

## Ключевые env (`.env`)

| Переменная | Значение у нас |
|------------|----------------|
| `CLUSTER_ID` | `operator-main` |
| `HOME_PORT` | `9205` |
| `HOME_NODE_ID` | `home-operator-main` |
| `DISCOVERY_NODE_URL` | `http://host.docker.internal:8003` (home) / `discovery-node:8003` (relay/storage) |
| `DISCOVERY_ADMIN_SECRET` | тот же, что в project discovery |
| `ENROLLMENT_MODE` | `strict` |

## Strict enrollment (fresh DB)

При `ENROLLMENT_MODE=strict` новые ноды регистрируются как **pending** на discovery (:8003).
Одобрение:

1. **Operator Console** — http://127.0.0.1:9205/ops → enrollment / pending → «Принять»
2. **Терминал** — из `backend/` или `project/` (тот же `DISCOVERY_ADMIN_SECRET`):
   `./scripts/approve-pending-nodes.sh --list` / approve all / `node_id`

После approve нода забирает одноразовый `node_token` через poll `POST /registry/enrollment/status`.
Полный чеклист: [backend ENROLLMENT-STRICT](../backend/ENROLLMENT-STRICT.md).

## Сети Docker

- `main-node_default` — внутренняя
- `project_default` (external) — доступ к `discovery-node`, **без** публикации home как `home-node` DNS

## Зависимости

- **project** (или backend) — поднятый `discovery-node`
- **project/admin** — статика для admin-server (volume mount)

## Что НЕ является main-node

- Папка `main-node/` **не содержит** исходников Python — правки home-node → `client-node/services/home-node/`
- Operator Admin UI → `project/admin/`

## Версии

[CHANGELOG.md](CHANGELOG.md)
