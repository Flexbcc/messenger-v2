# 0405. Multi-device continuity

## Статус
Draft

## Назначение
Несколько Client-устройств одного Identity ([[0004_GLOSSARY]]): регистрация,
согласованная история переписки и realtime-синхронизация без потери
сообщений, отправленных с другого устройства того же пользователя.

As-is сверка: [`docs/reality/R6-multi-device.md`](../../docs/reality/R6-multi-device.md).

Guideline: **U6 — Синхронизация устройств** (`docs/SERVER-PROTOCOL-GUIDELINE-v0.3.md`).

## Связанные документы
- [0400_CLIENT.md](0400_CLIENT.md) — offline-first, локальная БД per-device
- [0600_HOME_NODE.md](0600_HOME_NODE.md) — регистрация Device, fan-out (to-be: все активные Device)
- [0202_DELIVERY.md](0202_DELIVERY.md) — buffer, WS push
- [0303_CALLS.md](0303_CALLS.md) — multi-device call fan-out **вне** v0

## As-is (кратко, см. R6)

- Device регистрируются на Home; JWT несёт `device_id`.
- Fan-out и WS маршрутизируются **per-user**, не per-device; отправитель исключается из fan-out → другие устройства не видят own sends по WS.
- История: только `before=`; offline buffer keyed by `user_id`.
- Prekey bundle: первый `Device` пользователя — не полноценный multi-device crypto.

## v0 (в работе)

Минимальный continuity slice (sprint 2026-07-23):

| # | Требование | Сторона |
|---|------------|---------|
| 1 | **`after=`** query на `GET /conversations/{id}/messages` — сообщения новее cursor | Home |
| 2 | **Mirror own sends** — WS `{type: new_message}` (или эквивалент) на другие активные соединения того же `user_id`, кроме `sender_device_id` | Home |
| 3 | **Client catch-up on resume** — после reconnect / `onAppResumed`: для активных чатов `getMessages(…, after: localNewest)` и idempotent merge | Client |

Вне v0: per-device buffer, prekey selection, call fan-out, push per-device.

## Поведение клиента (v0)

- Локальная БД остаётся **per-device** (0400); синхронизация — pull + WS merge, не shared DB.
- Dedupe по `packet_id` / message id при merge обязателен (несколько WS + REST overlap).
- Настройки `devices.history_sync_default` / `sync.history_depth` (`settings_runtime.dart`) ограничивают глубину **initial** sync; `after=` покрывает **incremental** catch-up.

## Поведение Home (v0)

- Mirror не заменяет fan-out к другим участникам — только дополнение для siblings отправителя.
- `after=` должен быть стабильным cursor (рекомендация: ISO `created_at` + tie-break `id`, как у `before=`).

## Открытые вопросы (Post-v0)

- Prekey bundle: primary device vs per-device fetch by id.
- Storage buffer: per-device vs shared user queue + client idempotency.
- WS routing: optional `device_id` target для calls и selective notifications.
