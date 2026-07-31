# Strict enrollment — fresh DB checklist

Пошаговый сценарий для **пустой** БД discovery и ручного допуска нод.
См. ADR: [`backend/spec/ADR/0009-node-enrollment.md`](../../../backend/spec/ADR/0009-node-enrollment.md).

> **Не путать** с [`scripts/ppc_smoke/`](../../../scripts/ppc_smoke/README.md) — там smoke-тесты PPC/storage pairing (`ENROLLMENT_MODE=legacy` в compose), не операторский admission.

## Режимы

| `ENROLLMENT_MODE` | Поведение |
|-------------------|-----------|
| `legacy` | Регистрация → сразу `trusted` |
| `strict` | Любая новая нода → `pending` до approve |
| `hybrid` | Новый `node_id` → `pending`; уже `trusted` остаётся trusted |

Решение принимает **discovery-node** (порт **8003**). На client/main нодах тот же env нужен для poll `enrollment/status`, но `trust_status` задаёт discovery.

## Prerequisites

1. В `.env` **до первого** `docker compose up` на машине с discovery:
   ```env
   ENROLLMENT_MODE=strict
   DISCOVERY_ADMIN_SECRET=<длинный-случайный-секрет>
   ```
2. Один и тот же `DISCOVERY_ADMIN_SECRET` на discovery и в Operator Admin (main-node `.env` — для UI).
3. Для dev-лаба: канонический стек — `backend/` (или legacy `project/`); client/main подключаются к `DISCOVERY_NODE_URL`.

## Checklist (fresh DB)

### 1. Настроить strict

```bash
cd backend   # или project/
cp .env.example .env
# ENROLLMENT_MODE=strict
# DISCOVERY_ADMIN_SECRET=...
```

Удалите старый volume discovery, если нужен именно **чистый** реестр:

```bash
docker compose down
rm -rf data/discovery/*   # путь по вашему deploy; только если осознанно сбрасываете
```

### 2. Поднять стек

```bash
docker compose up -d --build
```

Discovery: `GET http://127.0.0.1:8003/health`  
Admin (backend stack): http://127.0.0.1:9201  
Operator Console (main-node): http://127.0.0.1:9205/ops — см. [main-node README](../main-node/README.md).

### 3. Запустить ноды — они появятся как pending

Поднимите `client-node/` или `main-node/` (или worker-ноды backend). Каждый сервис с `node_registration.py` делает:

1. `POST /registry/nodes` → ответ `trust_status: pending` + одноразовый `enrollment_secret`
2. Фоновый poll `POST /registry/enrollment/status` → «Awaiting operator approval»

Проверка (admin API):

```bash
cd backend
./scripts/approve-pending-nodes.sh --list
```

Ожидаемый вывод: таблица с `node_id`, `cluster_id`, `trust_status=pending`.

### 4. Одобрить — UI или скрипт

**Вариант A — Operator Console**

1. Откройте http://127.0.0.1:9205/ops (или :9201/enrollment на backend admin).
2. Раздел enrollment / pending — «Принять» для каждой ноды.
3. UI проксирует `POST /admin/registry/nodes/{node_id}/approve` с `X-Discovery-Admin-Secret`.

**Вариант B — терминал**

```bash
cd backend   # или project/ — тот же .env, что у discovery
./scripts/approve-pending-nodes.sh              # все pending
./scripts/approve-pending-nodes.sh home-cv7616931   # один node_id
```

Скрипт читает `DISCOVERY_ADMIN_SECRET` и `DISCOVERY_PORT` из `.env`; можно переопределить через env:

```bash
DISCOVERY_ADMIN_SECRET='...' ./scripts/approve-pending-nodes.sh --list
```

### 5. Проверить claim `node_token`

После approve discovery переводит ноду в `trusted`. Следующий poll ноды:

- `POST /registry/enrollment/status` → одноразовый `node_token` в ответе
- Нода пишет token в `NODE_TOKEN_PATH` (по умолчанию `/data/node_token` в контейнере)
- Heartbeat идёт с `Authorization: Bearer <node_token>`

**Признаки успеха:**

| Где | Что смотреть |
|-----|----------------|
| Логи home/relay/storage | `Enrollment complete — node_token claimed` |
| `./scripts/approve-pending-nodes.sh --list` | `trust_status=trusted`, pending пуст |
| `GET /registry/nodes` (публичный) | Нода в каталоге (только trusted) |
| Контейнер ноды | файл `node_token` в `/data/` |

Повторный approve для той же ноды не нужен; повторный poll без token вернёт `"Enrollment complete"`.

## Admin API (discovery :8003)

| Метод | Путь | Назначение |
|-------|------|------------|
| GET | `/admin/registry/nodes` | Все ноды incl. pending (operator view) |
| POST | `/admin/registry/nodes/{node_id}/approve` | pending → trusted, сброс token для re-claim |
| POST | `/registry/enrollment/status` | Poll/claim (нода, не admin) |

Заголовок admin: `X-Discovery-Admin-Secret: $DISCOVERY_ADMIN_SECRET`.  
Без секрета discovery отвечает **503** (`Admin API disabled`).

## Типичные ошибки

| Симптом | Причина |
|---------|---------|
| Ноды сразу `trusted` | `ENROLLMENT_MODE=legacy` или не перезапущен discovery |
| `401 Invalid admin secret` | Неверный `DISCOVERY_ADMIN_SECRET` в скрипте/UI |
| `503 Admin API disabled` | Пустой `DISCOVERY_ADMIN_SECRET` на discovery-node |
| Pending не исчезает после approve | Нода не poll'ит (discovery недоступен из контейнера) |
| `404 Unknown node_id` | Опечатка в `node_id` или нода ещё не регистрировалась |

## Связанные документы

- [backend SETTINGS (§3 enrollment)](../../../backend/docs/SETTINGS.md)
- [main-node — Operator Console :9205/ops](../main-node/README.md)
- [backend README](README.md) — порты и env
