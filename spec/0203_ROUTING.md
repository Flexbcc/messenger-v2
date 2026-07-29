# 0203. Маршрутизация

## Статус
Draft (R4) — модель to-be + profile **`mvp-json`** (LIVE).  
Сверка: [`docs/reality/R4-routing.md`](../../docs/reality/R4-routing.md).  
Roadmap: [`docs/DEVELOPMENT-ROADMAP.md`](../../docs/DEVELOPMENT-ROADMAP.md).

## Назначение
Как Packet / сообщение находит путь от отправителя к получателю;  
как обновляются маршруты; чем path звонков отличается от сообщений.

---

## Модель маршрутизации сообщений (to-be)

Порядок попыток (быстрый → надёжный):

1. **Прямая доставка** Home отправителя → Home получателя.
2. **Relay Node**, если прямой путь недоступен ([0601](0601_RELAY_NODE.md)).
3. **Storage Node** получателя, если Home/устройства недоступны ([0202](0202_DELIVERY.md)).

### Разрешение адреса (to-be)

`UserID → Home` через Discovery ([0604](0604_DISCOVERY_NODE.md)).  
Запись подписана; проверяется получателем (Zero Trust).  
Клиент кэширует с TTL; при смене Home — служебное CONTROL / notify пирам.

### Обновление маршрутов (to-be)

| Механизм | Смысл |
|----------|--------|
| TTL кэша Record / user→home | Периодический refresh |
| Version маршрута | Монотонная версия; stale отбрасывать |
| Backup routes | previous + N резервных Home/Relay |
| Notify при смене Home | Служебное сообщение контактам / republish |
| Rollback | Вернуться на previous при провале нового |

### Multi-hop (to-be)

Несколько Relay; каждый видит только соседние хопы (`sender_ref`, [0201](0201_PACKETS.md)).  
Mixnet не цель v1 ([0005](0005_DESIGN_PHILOSOPHY.md)).

### Недостижимость (to-be)

- Плохой Relay → следующий из списка Discovery.
- Home down → backoff + re-resolve; при новом адресе — пересчёт маршрута.

---

## Звонки vs сообщения (to-be)

| Плоскость | Сообщения | Звонки |
|-----------|-----------|--------|
| Signaling | MESSAGE / CONTROL | Может ехать тем же E2EE Message path (ADR-0008) |
| Media | — | Отдельный путь (TURN / P2P ICE), не Relay Node plaintext |
| Смена маршрута mid-session | re-route Packet | ICE restart / новый TURN; продукт mid-call switch — отдельная спека |
| Restore после обрыва | outbox/retry | явный rejoin protocol (to-be; MVP может не иметь) |

---

## Profile `mvp-json` (LIVE)

### Resolve

| Кто | Как | Cache TTL |
|-----|-----|-----------|
| Discovery | `GET /registry/users/{user_id}` → `home_node_url` | нет Expires |
| Home federation | live GET Discovery на каждый remote deliver | **нет** user→home cache |
| Client | **не** резолвит peer Home для send; знает только **свой** Home | нет |
| Gateway | catalog proxy / routing для bootstrap своего Home | не peer routes |

Подписанных user Discovery-записей в LIVE нет (спека опережает код).

### Смена Home

- `POST /registry/users` upsert `home_node_url` (часто `settings.public_url` при login/register).
- **Нет** notify пирам / CONTROL «home moved».
- Пиры узнают новый URL только на следующем live resolve.

Mesh notify (`peer-joined`) — для **нод**, не для user home.

### Выбор маршрута federation (на Home отправителя)

```
direct POST /internal/deliver
  → fail → ranked online trusted relays (health race)
       → POST /relay/forward → target /internal/deliver
            → all fail → log (нет outbox; см. R3)
```

| Есть | Нет |
|------|-----|
| Direct → multi-relay try | Versioned route, rollback |
| Relay list из Discovery/mesh | Client backup peer routes |
| Storage buffer для local offline WS | Storage как federation DLQ |
| | Multi-hop beyond one relay hop |

`resource_policy=local` → без relay.

### Клиент и маршруты пиров

Клиент хранит свой Home URL.  
Search может вернуть `home_node_url`, UI его не персистит как route table.  
Send всегда на свой Home; federation server-side.

### Звонки LIVE

| Signaling | Тот же `POST .../messages` + WS `new_message` с `content_type: call_*` |
| Media | Discovery `capability=turn` → `POST /turn/credentials` → ICE (+ Google STUN); coturn |
| Mid-call relay switch | **нет** |
| ICE disconnect | wait + `restartIce()` ~20s → teardown; без полного re-offer protocol |
| Call restore / rejoin | **нет** (только local history) |
| Relay Node | не возит RTP |

Наследует риски R3 (нет ACK, silent federation fail) — для ICE trickle критичнее.

---

## Целевые дополнения (Post-R5 / backlog)

1. TTL + подпись user→home Record; клиентский/home кэш.
2. CONTROL notify при смене Home + client previous/backup routes.
3. Durable outbox + route version (связь с R3).
4. TURN selection (geo/latency); JWT credentials в signed mode на клиенте.
5. Спека mid-call ICE renegotiation / restore — отдельным MINOR.

## Связанные документы

- [0202_DELIVERY.md](0202_DELIVERY.md), [0205_NODE_RECORD.md](0205_NODE_RECORD.md)
- [0303_CALLS.md](0303_CALLS.md), [ADR-0008](ADR/0008-calls-signaling-and-media-relay.md)
- [0601](0601_RELAY_NODE.md), [0604](0604_DISCOVERY_NODE.md), [0605](0605_TURN_NODE.md)
