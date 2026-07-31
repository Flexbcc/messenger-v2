# R0 — Карта LIVE

| Поле | Значение |
|------|----------|
| Фаза | R0 |
| Дата | 2026-07-22 |
| Трек | T2 Reality |
| Связанная спека (T1) | [`../DEVELOPMENT-ROADMAP.md`](../DEVELOPMENT-ROADMAP.md) |
| Статус заметки | confirms |

---

## As-is (как работает сейчас)

Кластерный MVP, не независимый mesh из многих операторов.

### Топология

| Роль | Хост | Сервисы |
|------|------|---------|
| **MAIN** | `194.67.92.147` | Discovery `:8003`, Gateway `:8007`, Gitea, Admin `:9201` (localhost), сайт/PWA nginx `:443` |
| **WORKER** | `161.104.18.45` | Home `:8001`, Media `:8004`, Storage, Relay, TURN `:8006` |

Код и деплой: `project/` → Gitea `flex/messenger` → `/opt/messenger/project` на серверах.

### Роли vs data / control plane

| Сервис | Плоскость | Назначение |
|--------|-----------|------------|
| **Gateway** | Bootstrap / вход клиента | Invite, routing bootstrap (`/gateway/routing`), иногда TLS/mTLS |
| **Discovery** | Control plane | Реестр нод, users→home, enrollment, trust, heartbeat |
| **Home** | Data plane | Клиенты, сообщения, federation |
| **Relay** | Data plane | Fallback доставки |
| **Media / Storage** | Data plane | Медиа / blobs |
| **TURN** | Calls | NAT traversal для WebRTC |

### Critical path

Без этих сервисов «сеть как продукт» не стартует для нового клиента/ноды:

1. **Gateway** — клиентский bootstrap (invite / nearest routing).
2. **Discovery** — каталог trusted-нод и resolve user→home.
3. **Home** — сессии и сообщения пользователя.

Relay/Media/TURN усиливают доставку и звонки, но без Gateway+Discovery новый участник в текущей модели не входит «сам по себе».

Подробности оператора: [`AI-HANDOFF.md`](../AI-HANDOFF.md).

---

## Confirms

- Нет единого «облака сообщений»: роли разнесены по нодам.
- Discovery не в data plane доставки (согласовано с ADR-0009).
- Gateway = точка входа; дальше клиент ходит на Home / каталог.
- E2EE на клиенте; медиа на Media/Storage, не как вечное хранилище сети.

---

## Gaps

| Gap | Влияние | Нужно в T1 / позже в коде |
|-----|---------|---------------------------|
| Один операторский кластер MAIN/WORKER | Нет свободной смены независимых Home как в гайдлайне | R4 (маршруты) + Post-R5 |
| Gateway/Discovery всё ещё single points of entry | «Жизнь без Bootstrap» не выполняется | R5 сценарии |
| Wire = HTTP/JSON+WS, не целевые Packet | Спека 0201 ≠ wire | R2 `mvp-json` profile |

---

## Что ломается

| Отказ | Эффект |
|-------|--------|
| Gateway down | Новые клиенты не получают bootstrap/routing; уже залогиненные на Home могут жить, пока не нужен re-bootstrap |
| Discovery down | Resolve user→home и каталог нод недоступны; federation деградирует; enrollment/heartbeat стоп |
| Home down | Пользователи этой Home offline; медиа/звонки на этом worker тоже страдают |
| Relay down | Прямая federation может работать; fallback через relay — нет |
| TURN down | Звонки за NAT хуже / ломаются; чаты живы |

---

## Feedback в T1

1. Явно зафиксировать LIVE как **cluster MVP profile**, отдельно от целевого mesh.
2. В R1 развести Bootstrap (Gateway) и Control Plane (Discovery).
3. Не закрывать «сеть автономна без Bootstrap», пока R5 не опишет механизм и T2 не подтвердит путь миграции.
