# backend — полный бекенд сети

## Назначение

Инфраструктура **всей сети**: Discovery ROOT, gateway, media, turn, enrollment, Operator Admin. Это «нода проекта» для оператора/хостинга сети.

## Папка в репозитории

`backend/`

## Статус

**Активный** (каноническая копия бекенда; параллельно живёт `project/` для dev).

## Сервисы (`services/`)

| Сервис | Порт | Роль |
|--------|-----:|------|
| `home-node` | 8001 | Auth, чаты, WS, федерация, `/panel` |
| `storage-node` | 8002 | Офлайн-буфер (internal) |
| `discovery-node` | 8003 | Реестр нод, UserID→Home, enrollment, audit |
| `media-node` | 8004 | Медиа-блобы |
| `relay-node` | 8005 | Пересылка пакетов (internal) |
| `turn-node` | 8006 | TURN credentials |
| `gateway-node` | 8007 / 8447 TLS | Bootstrap, catalog, invite |

## Панели и UI

| Компонент | Порт | Роль |
|-----------|-----:|------|
| `admin/` + `admin-server/` | 9201 | Operator Admin: мониторинг, узлы, доверие, setup |
| `operator/` | 9300 | Операторская консоль (localhost) |
| `webview/` | — | Просмотр markdown-спеки |

## Общий код

| Путь | Роль |
|------|------|
| `shared/` | security, mesh, federation helpers |
| `config/` | storage.json, deploy examples |
| `scripts/` | deploy, integration-test, approve-pending |
| `spec/`, `docs/` | ADR, HANDOFF, SETTINGS |

## Запуск

```bash
cd backend
cp .env.example .env
docker compose up -d --build
```

Admin: http://127.0.0.1:9201

## Ключевые env

| Переменная | Назначение |
|------------|------------|
| `ENROLLMENT_MODE` | `legacy` / `strict` / `hybrid` |
| `DISCOVERY_ADMIN_SECRET` | Пароль admin API discovery |

Strict enrollment (fresh DB, approve pending, verify token): [ENROLLMENT-STRICT.md](ENROLLMENT-STRICT.md).
| `CLUSTER_ID` | Метка площадки (default) |

## Зависимости

- **client-node**, **main-node** — подключаются к `discovery-node:8003`
- **frontend** — HTTP/WS к home/media/gateway

## Отличие от client-node

`client-node` — только home+storage+relay у пользователя. Здесь — **вся сеть** включая Discovery ROOT.

## Версии

[CHANGELOG.md](CHANGELOG.md)
