# R3 — Message lifecycle (as-is)

| Поле | Значение |
|------|----------|
| Фаза | R3 |
| Дата | 2026-07-22 |
| Трек | T2 Reality |
| Связанная спека (T1) | [`../../project/spec/0202_DELIVERY.md`](../../project/spec/0202_DELIVERY.md) |
| Статус заметки | confirms |

Исследование: home fanout/federation, relay/storage buffer, Flutter send/WS  
([агенты](a62d179b-04dc-4fbe-a64d-69bb6250c03e) · [relay/buffer](9ded82a0-77b9-4a76-a343-c2cc04bfeeca) · [client](31fe91f7-f6df-4176-9be3-850ed74fb26e)).

---

## As-is

### Send (Local Home)

1. Client `POST /conversations/{id}/messages` (`messages.py` → `send_message`).
2. Insert `messages` (SQLite), commit.
3. `fan_out_message` (`fanout.py`) — best-effort после ответа клиенту по сути того же запроса (ответ после fanout await, но ошибки remote не валят send).
4. Поля: id, conversation, sender, client_msg_id, ciphertext, … — **без** delivery status.

### Local participant

- WS online → `ConnectionManager.send_to_user` → `{type: new_message, message: envelope}`.
- Иначе → `buffer_for_offline_user` → Storage `POST /buffer`, TTL **30d**, ключ = `user_id` в поле `recipient_device_id`.
- WS connect → `drain_buffer` → GET → push WS каждой записи → **DELETE только при успешном push** (Post-R5; было DELETE до push, см. Gaps/Post-R5 update).

### Remote participant

1. Discovery resolve home.
2. `POST {peer}/internal/deliver` (~5s).
3. Fail → ranked relays → `POST /relay/forward` (~10s) → peer deliver.
4. All fail → **log warning**, без outbox/requeue.
5. Peer: upsert conversation, idempotent insert by `packet_id`, local WS or buffer.

### Relay

Stateless sync hop; **нет** очереди/TTL сообщений (`relay-node/app/main.py`).

### Client

| Факт | Деталь |
|------|--------|
| Send gate | session + WS connected; **нет** offline outbox |
| Status | `sending` → `sent` после REST 200; `delivered` — wire `delivery_ack` (Post-R5) или эвристика peer online до внедрения |
| Retry | ручной для текста (новый `client_msg_id`); attachments слабо |
| E2e delivery ACK | **done (Post-R5):** recipient `POST …/ack` → sender WS `delivery_ack` → `MessageDeliveryStatus.delivered` |
| Hop ACK packet | **нет** (to-be) |
| Read receipt | encrypted control «прочитано»; **не** `delivered` и **не** delivery ACK |
| WS | receive-only для сообщений |

Код: `app_controller.dart`, `realtime_service.dart`, `message_delivery_store.dart`.

---

## Confirms

- At-least-once **частично**: local persist + dedupe `packet_id` на receive; remote fail может **потерять** доставку при живой копии только у отправителя.
- Storage buffer = offline **local devices**, не «все неудачи federation».
- Relay не хранит; соответствует «не читать plaintext», но не durable queue.
- R2 gap «нет ACK» подтверждён на момент R3; Post-R5 добавляет **e2e** delivery ACK (не hop ACK).

---

## Gaps

| Gap | Влияние | Нужно в T1 / позже в коде |
|-----|---------|---------------------------|
| ~~Нет e2e ACK~~ → **e2e ACK wire (Post-R5)** | `delivered` на wire; buffer purge **по-прежнему** WS-success, не ACK | **частично закрыто** — см. Post-R5 update ниже; hop ACK — backlog |
| Нет hop-by-hop ACK | Нет подтверждения на каждом hop | 0202 to-be |
| Нет outbox на federation fail | Тихая потеря remote delivery | Post-R5 durable outbox |
| DELETE buffer до client ACK | Purge buffer **намеренно** не ждёт client ACK (WS-success only); риск потери между WS write и client process | Частично: Post-R5 drain (DELETE после push); e2e ACK **не** триггерит purge |
| Client offline не шлёт | UX: нельзя писать без WS | Client outbox — Post-R5 / продукт |
| `delivered` UI vs wire | До ACK — эвристика peer online; после — `delivery_ack` | **частично закрыто** Post-R5 wire; read_receipt ≠ delivered |
| Per-user buffer key | Не per-device | backlog multi-device (R4/U6) |

### Post-R5 update: federation outbox реализован

Строка «Нет outbox на federation fail» выше описывала LIVE на момент R3.
После R3 добавлен durable outbox (`home-node/app/models.py::MessageOutbox`,
`home-node/app/outbox.py`): при провале `deliver_to_remote_home_node` (direct
+ все relay) в `fan_out_message` (`fanout.py`) строка ставится в очередь
вместо только лога. Фоновый воркер (asyncio-loop, старт в `main.py` рядом с
`start_node_registration`) поднимает due-строки, повторяет доставку с
экспоненциальным backoff (`2s * 2^attempts`, cap 1h), при retry
переразрешает Home через Discovery (`resolve_home_node`) на случай устаревшего
URL, и помечает `dead` после `MAX_ATTEMPTS=20`. Это server-side federation DLQ:
outbox retry означает «remote Home принял `/internal/deliver`», **не** e2e —
семантика `deliver_to_remote_home_node` не менялась; e2e «доставлено» — отдельный
wire Post-R5 (`/ack` → `delivery_ack`).

### Post-R5 update: semantic e2e delivery ACK (wire в работе)

На момент R3 e2e/hop ACK **не было** (строка Gaps выше). Post-R5 вводит **только e2e**
delivery ACK в profile `mvp-json` (hop-by-hop Packet ACK по-прежнему to-be):

| Компонент | Поведение |
|-----------|-----------|
| Recipient client | `POST /conversations/{id}/messages/{packet_id}/ack` после приёма сообщения |
| Home | Persist `message_delivery_acks` (idempotent) |
| Sender notify | WS `{type: delivery_ack, …}` локально или через `POST /internal/delivery-ack` federation |
| Sender client | `MessageDeliveryStatus.delivered` на событие `delivery_ack` |

**Не входит в этот wire:** hop ACK; purge Storage buffer по client ACK — buffer DELETE
остаётся при успешном WS push (`drain_buffer`), как в update ниже.

**`delivered` vs read_receipt:** `delivered` = клиент получателя подтвердил приём через REST ACK.
`read` / read receipt = отдельный прикладной сигнал «открыли/прочитали в UI»; не подменяет
delivery ACK и не должно выставлять `delivered` без `delivery_ack`.

### Post-R5 update: drain race (DELETE-до-ACK) частично исправлен

Строка «DELETE buffer до client ACK» / «Drain: DELETE затем WS fail» выше
описывала LIVE на момент R3: `drain_buffer` (`home-node/app/federation.py`)
делал GET всех записей → DELETE каждой → и только потом код в
`routers/ws.py` пушил их по WS — DELETE не зависел от результата push.

После R3 порядок инвертирован: `drain_buffer` теперь принимает callback
`deliver` и для каждой записи сначала вызывает его (в `routers/ws.py` —
`manager.send_to_user` на только что принятый WS), и **DELETE делает только
если push вернул успех**; на неудаче запись остаётся в buffer до следующего
reconnect. TTL/lazy purge на стороне Storage не менялись. Purge buffer **не**
привязан к e2e client ACK (Post-R5): DELETE только после успешного WS push.
Остаётся **частичным** исправлением to-be «purge after e2e ACK» — «доставлено»
для buffer = «успешный `send_to_user` на этот сокет»; e2e ACK подтверждает
приём на клиенте получателя, но **не** откладывает DELETE buffer.

---

## Что ломается

| Сценарий | Поведение |
|----------|-----------|
| Remote home + все relay down | Sender видит успех; peer не получает; нет авто-retry |
| Получатель offline, Storage down | Local fanout buffer fail (зависимость от обработки ошибок); история на Home отправителя есть |
| Drain: WS push успешен, но клиент не обработал | Запись удалена из buffer (send_to_user True); e2e ACK может не успеть до DELETE — осознанный trade-off |
| Buffer >30d без GET | Lazy expire на следующем GET; orphan до обращения |
| Клиент без сети | Не отправит; pending только если уже failed после попытки |

---

## Feedback в T1

1. Развести **to-be ACK lifecycle** и **mvp-json best-effort** (**сделано в 0202**).
2. Явно: Storage ≠ federation DLQ.
3. R4 опирается на этот путь (direct → relay → buffer) без выдуманного ACK.
4. Не смешивать read_receipt и delivery ACK (**сделано в 0202 Post-R5**; wire e2e ACK в работе).
