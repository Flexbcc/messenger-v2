# R1 — Node bootstrap & trust (as-is)

| Поле | Значение |
|------|----------|
| Фаза | R1 |
| Дата | 2026-07-22 |
| Трек | T2 Reality |
| Связанная спека (T1) | [`../../project/spec/0205_NODE_RECORD.md`](../../project/spec/0205_NODE_RECORD.md) |
| Статус заметки | confirms |

---

## As-is

### Вход новой ноды (WORKER)

1. Нода поднимается с `node_id`, `node_url`, списком `capabilities`.
2. `node_registration.py` регистрируется в Discovery (`RegisterNodeCapability`).
3. По `ENROLLMENT_MODE`:
   - **legacy** (дефолт прод-часто): сразу `trust_status=trusted`.
   - **strict / hybrid**: `pending` + одноразовый `enrollment_secret` → admin approve → `node_token` → Bearer на heartbeat.
4. Heartbeat обновляет `last_heartbeat` → `reachability` online/offline (порог ~120 с).
5. Attestation-поля (`build_hash`, TLS fingerprint, release signature) пишутся при наличии (ADR-0010).

### Вход клиента

1. Bootstrap через **Gateway** (invite / `GET /gateway/routing`).
2. Home для аккаунта; user record в Discovery (`user_id` → `home_node_url` + `auth_public_key`).
3. Дальше data plane = Home (+ federation/relay), не Gateway.

### Trust as-is

| Поле | Значения |
|------|----------|
| `trust_status` | `pending`, `trusted`, `suspended`, `compromised`, `unknown` |
| `reachability` / `status` | `online` / `offline` |
| Публичный `GET /registry/nodes` | только `trusted` |
| Admin | approve / suspend / reinstate / compromise |

**Нет** в коде: L0–L5 enum, Trust Score history 7/30d, ValidatorSignatures, Expires на Record, Capacity Score в каталоге.

Код сверки: `project/services/discovery-node/app/schemas.py`, `db.py`, ADR-0009.

---

## Confirms

- Discovery = Control Plane; не возит сообщения.
- Gateway = Bootstrap / вход; не замена Discovery.
- Две оси: trust ≠ reachability.
- Роли ноды = `capabilities[]` (relay/home/…), а не отдельный trust tier.
- Публичный каталог фильтрует недоверенных.

---

## Gaps

| Gap | Влияние | Нужно в T1 / позже в коде |
|-----|---------|---------------------------|
| L0–L5 не в wire | Гайдлайн и API говорят на разных языках | Mapping в `0205` (сделано); код — Post-R5 |
| `legacy` → сразу trusted | Sybil-лёгкий вход в дефолтном режиме | R5 + ops: `strict` на проде |
| Нет `Expires` / validator sigs | Кэш Record и «доказательство» слабые | R2/R4 (TTL), R5 (валидаторы) |
| Нет L1 Observed / истории метрик | Нет постепенного роста доверия | R5 Sybil design |
| Signing key optional | Node Record без обязательного PublicKey | Ужесточить в to-be; код позже |
| Один `node_url` | Нет multi-address | backlog Record |

---

## Что ломается

| Сценарий | Поведение |
|----------|-----------|
| Discovery down | Новые регистрации/heartbeat/resolve падают; уже известные home URL у клиентов могут временно жить из кэша (не специфицировано жёстко) |
| Gateway down | Новые клиенты без bootstrap; ноды уже в Discovery продолжают heartbeat |
| Нода `suspended` / `compromised` | Исчезает из публичного каталога; federation не должна выбирать её (`trust_status=trusted` filter) |
| Heartbeat протух | `reachability=offline`; trust может остаться `trusted` |

---

## Feedback в T1

1. Зафиксировать mapping L0–L5 ↔ `trust_status` без требования немедленной смены enum (**сделано в 0205**).
2. Явно: Bootstrap=Gateway, Control Plane=Discovery.
3. Пометить `Expires` + validator signatures как to-be, heartbeat — MVP TTL-суррогат.
4. Для R5: `ENROLLMENT_MODE=legacy` = осознанный security trade-off MVP, не целевая Sybil-модель.
