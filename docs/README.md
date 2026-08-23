# Документация Messenger

Цель: работать над **каждым модулем отдельно**, не загружая в контекст весь репозиторий.

## Целевая безопасность OUO v1

- [Security Architecture & Threat Model v1](OUO-SECURITY-ARCHITECTURE-v1.md)
- [Implementation roadmap и gap-анализ](OUO-SECURITY-IMPLEMENTATION-ROADMAP-v1.md)
- [Каталог threat tests инфраструктуры](OUO-THREAT-TEST-CATALOG-v1.md)
- [Read-only аудит Proxmox](ops/PROXMOX-READONLY-AUDIT.md)
- [Secure compose baseline для нод](ops/SECURE-NODE-COMPOSE.md)
- [Migration и fail-closed security profiles](ops/SECURITY-PROFILES.md)
- [Локальный восьмипроцессный кластер и проверки](ops/LOCAL-NODE-CLUSTER.md)
- [Trust/Sybil simulator](ops/TRUST-SIMULATOR.md)
- [Emergency Authority Recovery runbook](ops/AUTHORITY-RECOVERY.md)

## Как пользоваться

1. Откройте **только** папку модуля, над которым работаете (`docs/modules/<имя>/`).
2. Прочитайте `README.md` — что это, границы, порты, зависимости.
3. Прочитайте `CHANGELOG.md` — что уже сделано и в какой версии.
4. После изменений — допишите запись в `CHANGELOG.md` модуля (не забудьте версию и дату).

Подробный workflow: [HOW-TO-WORK.md](HOW-TO-WORK.md).

## Карта модулей

| Модуль | Папка в репо | Статус | Документация |
|--------|--------------|--------|--------------|
| Flutter-клиент | `frontend/` | активный | [modules/frontend/](modules/frontend/) |
| Полный бекенд сети | `backend/` | активный | [modules/backend/](modules/backend/) |
| Slim-нода (пользователь) | `client-node/` | активный | [modules/client-node/](modules/client-node/) |
| Главная нода оператора | `main-node/` | активный | [modules/main-node/](modules/main-node/) |
| Dev-стек (оригинал) | `project/` | legacy / dev | [modules/project/](modules/project/) |
| Личное хранилище ПК | `storage-app/` | в разработке | [modules/storage-app/](modules/storage-app/) |
| Симуляция сети | `simulation/` | скелет | [modules/simulation/](modules/simulation/) |

## Связи между модулями (кратко)

```
backend/ или project/     ← Discovery ROOT, gateway, media, admin
        │
        ├── client-node/  ← подключается по DISCOVERY_NODE_URL
        ├── main-node/    ← то же, но CLUSTER_ID=operator-main, :9205/ops
        └── frontend/     ← HTTP/WS к home-node, media, discovery
```

**Код не дублируется бесконечно:** `backend/` и `project/` — копии одного стека; `main-node/` собирается из `client-node/`.

## Устаревшее и корень репо

- [legacy/README.md](legacy/README.md) — что считать старым, куда смотреть вместо этого.
- [WORKSPACE.md](../WORKSPACE.md) — исходное описание разбиения (2026-07-14).
- [AUDIT.md](../AUDIT.md) — сверка доков и кода.

## Шаблон для нового модуля

Скопируйте [modules/_template/](modules/_template/) и заполните `README.md` + `CHANGELOG.md`.
