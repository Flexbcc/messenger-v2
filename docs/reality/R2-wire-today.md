# R2 — Wire сегодня (mvp-json)

| Поле | Значение |
|------|----------|
| Фаза | R2 |
| Дата | 2026-07-22 |
| Трек | T2 Reality |
| Связанная спека (T1) | [`../../project/spec/0200_PROTOCOL.md`](../../project/spec/0200_PROTOCOL.md), [`0201_PACKETS.md`](../../project/spec/0201_PACKETS.md) |
| Статус заметки | confirms |

---

## As-is

Транспорт: **HTTP JSON + один receive-oriented WebSocket**.  
Нет бинарного Packet-stream, нет `HANDSHAKE` packet, нет protocol `session_id`.

### Client ↔ Home

| Шаг | Endpoint / канал | Auth |
|-----|------------------|------|
| Register | `POST {home}/auth/register` | password + `auth_public_key` + identity bundle |
| Login | `POST {home}/auth/login` | identifier + password (+ device keys) |
| Challenge | `POST {home}/auth/challenge` `{device_id}` | → nonce, TTL **120s** (память процесса) |
| Verify | `POST {home}/auth/verify` | Ed25519 signature → **JWT** |
| REST API | `Authorization: Bearer <jwt>` | JWT HS256, TTL **7 дней** |
| WS | `WS {home}/ws?token=<jwt>` | query token; fail → close **4401** |

Код: `home-node/app/routers/auth.py`, `security.py`, `routers/ws.py`; клиент `api_client.dart`, `realtime_service.dart`, `session_store.dart`.

Поток сообщений:
- **Send:** `POST /conversations/{id}/messages`
- **History:** `GET /conversations/{id}/messages`
- **Push:** WS `{type:"new_message", message: <envelope>}`
- При connect: drain Storage buffer → те же `new_message`

### Node ↔ Discovery / peers

| Действие | Endpoint | Auth |
|----------|----------|------|
| Register node | `POST {discovery}/registry/nodes` | body Record |
| Enrollment poll | `POST /registry/enrollment/status` | `enrollment_secret` |
| Heartbeat | `POST /registry/nodes/{id}/heartbeat` | Bearer `node_token` (после approve); период **60s**; offline **~120s** |
| Resolve user | `GET /registry/users/{user_id}` | публичный в MVP |
| Deliver | `POST {peer}/internal/deliver` | optional `X-Federation-*` если `signed` |
| Relay | `POST {relay}/relay/forward` | → deliver |
| Buffer | storage `/buffer/...` | offline local user |

Gateway: bootstrap (`/gateway/routing`, invite) — не message handshake; mTLS опционален только там.

### Message Envelope (факт)

См. `project/shared/README.md`: `packet_id`, `type`, `conversation_id`, `sender_*`, `crypto_version`, `ciphertext`, `content_type`, `created_at`.

---

## Таблица: логический type ↔ LIVE

| Spec type | LIVE | Комментарий |
|-----------|------|-------------|
| MESSAGE | REST + WS + `/internal/deliver` | единственный first-class |
| ACK | нет | HTTP 200 ≠ ACK |
| HANDSHAKE | `/auth/*` + JWT | не packet |
| PRESENCE | WS online / ping / typing | не packet |
| DISCOVERY_* | `/registry/*`, Gateway catalog | REST |
| CONTROL | prekeys, devices, security-signals, … | REST россыпью |

---

## Confirms

- Password — bridge (ADR-0007); Ed25519 challenge существует и используется для refresh.
- Envelope JSON задуман как мост к будущему Packet (имена полей).
- Discovery/enrollment отделены от client session (Bearer node_token ≠ JWT user).
- E2EE ciphertext серверам непрозрачен.

---

## Gaps

| Gap | Влияние | Нужно в T1 / позже в коде |
|-----|---------|---------------------------|
| Нет protocol version на connect | Нельзя отказать по MAJOR | R2 спека зафиксировала gap; enforce — Post-R5 / 0204 |
| Нет ACK packet | Нет явного purge по подтверждению клиента | **R3** lifecycle |
| Нет session_id / state machine | «Session» = JWT only | to-be в 0200; код не сейчас |
| WS не multiplex Packet send | Два канала (REST+WS) | допустимо для mvp-json |
| Challenge in-memory | Не multi-instance safe | ops / позже shared store |
| `INTERNAL_SECURITY_MODE=legacy` часто | Federation без жёсткой подписи | R5 / ops `signed` |
| shared/README говорит «пароль не используется» | Расходится с LIVE primary login | T1: 0200 честно описывает bridge; shared README — уточнить при случае |

---

## Что ломается

| Сценарий | Поведение |
|----------|-----------|
| JWT истёк | REST 401; клиент challenge/verify или password login |
| WS без валидного token | close 4401; reconnect после нового JWT |
| Challenge >120s | verify fail; нужен новый challenge |
| Discovery down | resolve/federation деградируют; уже открытый Home+JWT могут жить |
| Home restart (challenge store) | pending challenges потеряны; JWT всё ещё валиден до exp |

---

## Feedback в T1

1. Зафиксировать `mvp-json` как канон LIVE (**сделано в 0200/0201**).
2. Не требовать HANDSHAKE packet для закрытия R2 — только mapping.
3. R3 обязан описать отсутствие ACK и что считать «доставлено» сегодня.
4. Уточнить `shared/README.md` Identity-секцию (password bridge) в следующем проходе docs — не блокер R2 done.
