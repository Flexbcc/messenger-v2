# R6 — Multi-device continuity (as-is)

| Поле | Значение |
|------|----------|
| Фаза | R6 |
| Дата | 2026-07-23 |
| Трек | T2 Reality |
| Связанная спека (T1) | [`../../project/spec/0405_MULTI_DEVICE.md`](../../project/spec/0405_MULTI_DEVICE.md), [0600](../../project/spec/0600_HOME_NODE.md) |
| Статус заметки | confirms (v0 landed 2026-07-23) |

Исследование: [multi-device as-is](953d885a-e086-48bf-b4e9-132240228b37).

---

## As-is

### Регистрация и сессия

1. При `POST /auth/register` и login-with-new-device Home создаёт строку `Device` и возвращает `device_id` + JWT.
2. JWT claims: `sub` = `user_id`, `device_id` = id устройства (`auth.py` → `create_access_token`).
3. `GET /me/devices`, `DELETE /me/devices/{device_id}` — список и отзыв чужих устройств; несколько Device на одного User поддерживаются в модели.

### Fan-out и WebSocket — per-user, не per-device

| Слой | Факт |
|------|------|
| WS | `ConnectionManager` (`ws.py`) ключ = `user_id`; несколько сокетов на user допустимы, но доставка не адресуется конкретному `device_id`. |
| Fan-out | `fan_out_message` / `deliver_locally_for_federated_message` (`fanout.py`) — `manager.send_to_user(user_id, …)` или buffer; комментарий в коде: MVP per-user, не per-Device. |
| Отправитель | Участник с `user_id == message.sender_user_id` пропускается в основном fan-out к пирам, затем **mirror** `send_to_user(sender)` для других устройств (v0, 2026-07-23). |
| History | `before=` (назад) + **`after=`** (catch-up, asc) |
| Client catch-up | `onAppResumed` → `_catchUpMessagesAfterResume` по открытым/недавним чатам |
| `home_changed` | `PeerHomeCache` + UI connection status |

### История

- `GET /conversations/{id}/messages` — **`before=`** (назад, desc) и **`after=`** (catch-up, asc) (`messages.py`, v0 2026-07-23).
- Client: `onAppResumed` → `_catchUpMessagesAfterResume` / `_catchUpConversation` с watermark = newest local `createdAt`.

### Offline buffer

- Storage buffer ключ = **`user_id`** в поле `recipient_device_id` (`federation.py::buffer_for_offline_user`) — не per-device.
- Первый reconnect любого устройства пользователя → `drain_buffer` → WS push → DELETE при успехе (R3 Post-R5).
- Второе устройство, подключившееся позже, **не получит** уже drained записи из buffer.

### Prekey bundle

- `GET /users/{user_id}/prekey-bundle` (`devices.py`): `select(Device).where(user_id).first()` — **один произвольный Device**, не выбор по `device_id` и не агрегация всех устройств.
- Отправитель X3DH-сессии может установиться с «не тем» устройством получателя; multi-device E2EE — gap.

Код: `fanout.py`, `ws.py`, `messages.py`, `devices.py`, `auth.py`, `federation.py`; client — `app_controller.dart`, `api_client.dart`.

---

## Confirms

- Несколько Device на User в БД и JWT с `device_id` — совпадает с намерением 0600 («несколько Device»).
- `sender_device_id` сохраняется в `Message` и попадает в envelope — клиент может отличить «своё устройство» vs «другое устройство того же user» (client-side фильтр частично есть для secret-chat control).
- Per-user WS set позволяет держать phone + desktop online одновременно для **входящих от других пользователей** (оба сокета получают `new_message`).

---

## Gaps

| Gap | Влияние | Нужно в T1 / позже в коде |
|-----|---------|---------------------------|
| Fan-out skip sender | Phone отправил — tablet не видит своё сообщение без REST history | v0: mirror WS на другие Device того же user (roadmap #14) |
| Нет `after=` history | Resume / второе устройство не догоняет только что пропущенное | v0: `after=` + client catch-up on resume |
| Buffer per user_id | Drained на первом online device; siblings теряют offline queue | v0+: per-device buffer или shared drain + idempotent client merge |
| Prekey = `Device.first()` | Неверный/устаревший bundle для multi-device crypto | T1: device picker / primary device / bundle per device_id |
| WS не per-device | Нельзя адресовать push одному устройству (calls, selective sync) | Post-v0; см. 0303 calls multi-device backlog |
| Client history sync без cursor | Полная перезагрузка limit=100, не incremental | v0 client: `after=` + local high-water mark |

---

## Что ломается

| Сценарий | Поведение |
|----------|-----------|
| User шлёт с phone, tablet online | Tablet **не** получает WS; история на tablet устаревает до ручного refresh / reopen chat |
| User offline на всех devices; phone reconnect | Buffer drain на phone; tablet при позднем входе **пустой** buffer |
| Новое устройство после pairing | REST history (`before=`) даёт прошлое; **нет** догона событий между pairing и первым fetch без `after=` |
| Peer запрашивает prekey | Может получить bundle не того Device → decrypt fail или wrong session |
| Два WS одного user | Оба получают входящие; дубликаты client dedupe по `packet_id` |

---

## Feedback в T1 (v0 goals)

Цели спринта для [`0405_MULTI_DEVICE.md`](../../project/spec/0405_MULTI_DEVICE.md):

1. **`after=`** на `GET …/messages` — cursor по `created_at` / id для catch-up после last local message.
2. **Mirror own sends** — после local send fan-out (или отдельный WS event) на **другие** соединения того же `user_id`, исключая `sender_device_id`.
3. **Client catch-up on resume** — при `onAppResumed` / WS reconnect: для открытых чатов запрос `after=<local newest>` и merge без полного re-fetch.

Связь: Guideline **U6** (синхронизация устройств) — было ✗; после v0 → ◐.
