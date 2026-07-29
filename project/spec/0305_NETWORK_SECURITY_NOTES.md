# 0305. Сетевая безопасность (заметки R5)

## Статус
Draft (R5) — спроектировано **на бумаге**; реализация = Post-R5.  
Сверка: [`docs/reality/R5-security-as-is.md`](../../docs/reality/R5-security-as-is.md).  
База угроз: [0302_THREAT_MODEL.md](0302_THREAT_MODEL.md).  
Trust mapping: [0205_NODE_RECORD.md](0205_NODE_RECORD.md).

## Назначение
Закрыть Part III Guideline: Sybil, revocation, malicious relay, metadata
level, partition, жизнь без Bootstrap — как **целевые политики MVP→mesh**,
без требования немедленного кода.

---

## 1. Sybil

### Цель
Сделать массовое появление ложных нод дорогим или бесполезным для
попадания в data plane (relay/home selection).

### MVP-политика (сейчас → усиление ops)

| Режим | Политика |
|-------|----------|
| `ENROLLMENT_MODE=legacy` | **Не** Sybil-safe; только lab/single-operator |
| `strict` / `hybrid` | Единственный контроль: ручной approve + `node_token` |
| Attestation / mTLS | Опциональные allowlists (ADR-0010); default off |

### Целевой алгоритм (to-be, кратко)

1. **Admission:** новая нода = L0/`pending` до approve или до накопления Observation.
2. **Observation (L1):** минимальный возраст + успешные heartbeats + нет critical faults (история 7/30d — из Guideline).
3. **Active (L2):** `trusted` + online; право обслуживать клиентов своего оператора.
4. **Relay (L3):** отдельно от L2 — нужна положительная статистика forward (успех/latency) от нескольких Home; порог задаёт политика сети.
5. **Validator (L4) / Root (L5):** подписи Record; Root постепенно необязателен (ADR-0006).

Запрещено в v1: полагаться только на self-reported Capacity без Observation.

**Не входит в v1:** PoW/stake, mixnet decoys (0302 §9).

---

## 2. Отзыв и компрометация нод

### Статусы LIVE (сохраняем)

`pending` → `trusted` → `suspended` | `compromised`  
(+ `unknown` legacy). Reachability отдельно.

### Целевой runbook

| Событие | Действие Control Plane | Data plane | Re-key |
|---------|------------------------|------------|--------|
| Подозрение | `suspended` | убрать из каталога; heartbeat reject | token optional keep |
| Подтверждённый breach | `compromised` | как suspend + revoke `node_token` | обязательный re-enroll + новые ключи подписи |
| Восстановление | только через **re-enroll** (новый enrollment), не silent approve | после approve снова в каталоге | rotate federation signing keys |

**Дыра to-fix:** должен существовать явный API/процедура re-enroll для `compromised` (сегодня sticky без пути — см. reality).
**Post-R5 LIVE:** `POST /admin/registry/nodes/{node_id}/re-enroll` реализован — сброс `compromised`/`suspended` в `pending` + новый `enrollment_secret`, ручной approve дальше (см. reality).

**Notify:** при suspend/compromise — push/mesh event пирам (не только ждать следующего GET catalog).

Пользователи на скомпрометированной Home **не** банятся автоматически; оператор мигрирует user→home (R4 notify).

---

## 3. Злонамеренный Relay

### Что Relay может (принято)

Задержка, drop, ложь о load, корреляция timing/size (0302 §2).  
Не читает plaintext (E2EE).

### Политика ответа (to-be)

| Сигнал | Реакция |
|--------|---------|
| Forward fail / timeout | Home пробует следующий Relay (уже LIVE) |
| Систематический fail от многих Home | demote score → исключить из L3; при пороге → `suspended` |
| Ложь о capacity | не доверять self-report без Observation; квоты сверять с probe |
| Сбор статистики | принятый остаточный риск v1; padding/mix — out of scope |

**Нет в v1:** cryptographic fraud proofs.  
**Есть в v1 design:** multi-path retry (R3/R4) + operator revoke + будущий Trust Score.

---

## 4. Уровень защиты метаданных (честный v1)

| Слой | Защита v1 |
|------|-----------|
| Message body | E2EE — да |
| Media content | Client encrypt before Media — да (цель) |
| Кто с кем | Home и часто Relay `conversation_meta` / participants — **видно** |
| Когда / объём | Да, операторам path — **видно** |
| Social graph via Discovery resolve | **высокий риск** — минимизация: rate limit, no mass enumeration (0604) |
| Mixnet / constant-rate cover | **не цель v1** |

Целевой уровень v1: **конфиденциальность содержимого + ограничение одного Relay**;  
не анонимность связи.

Улучшения Post-R5 (optional MINOR): убрать `participant_user_ids` из relay-visible meta; signed opaque `sender_ref` only.

---

## 5. Partition сети (EU ↔ Asia)

### Сценарий
Два региона теряют IP-связность; внутри региона ноды живы.

### Желаемое поведение (to-be)

1. **Intra-partition:** доставка и звонки внутри региона продолжаются.
2. **Cross-partition:** сообщения в outbox с backoff; после схождения — flush (связь с R3 durable outbox).
3. **Discovery:** ideally ≥1 реплика Record в каждом регионе (gossip); иначе resolve cross-region fail до восстановления.
4. **Не** объявлять глобальный split-brain merge пользователей без ADR.

### LIVE

Не реализовано; один Discovery SPOF → cross-home delivery падает при его недоступности.

---

## 6. Жизнь без Bootstrap (Gateway / корневой Discovery)

### Цель Guideline
Сеть уже участвующих нод **продолжает** жить, если Bootstrap исчез.

### Фазы миграции (to-be)

| Фаза | Условие | Bootstrap |
|------|---------|-----------|
| A (сейчас) | Cluster MVP | Gateway + Discovery обязательны для join |
| B | Multi-Discovery sync / mesh peer cache | Gateway только для **новых** клиентов |
| C | Клиенты хранят backup Home + peer Discovery URLs | Новый клиент может войти через любой trusted peer (QR/invite offline) |
| D | Root Authority необязателен | L4 validators подписывают Record |

Минимум для «да, сеть жива без Gateway»: фазы B+C для **уже** записанных клиентов/нод; новые joiners могут требовать альтернативный Bootstrap.

---

## Связанные документы

- [0302_THREAT_MODEL.md](0302_THREAT_MODEL.md)
- [ADR-0006](ADR/0006-staged-decentralization-bootstrap-authority.md), [ADR-0009](ADR/0009-node-enrollment.md)
- [0202](0202_DELIVERY.md), [0203](0203_ROUTING.md), [0205](0205_NODE_RECORD.md)
- Guideline: [`docs/SERVER-PROTOCOL-GUIDELINE-v0.3.md`](../../docs/SERVER-PROTOCOL-GUIDELINE-v0.3.md)
