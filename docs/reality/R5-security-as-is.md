# R5 — Network security (as-is)

| Поле | Значение |
|------|----------|
| Фаза | R5 |
| Дата | 2026-07-22 |
| Трек | T2 Reality |
| Связанная спека (T1) | [`../../project/spec/0305_NETWORK_SECURITY_NOTES.md`](../../project/spec/0305_NETWORK_SECURITY_NOTES.md), [0302](../../project/spec/0302_THREAT_MODEL.md) |
| Статус заметки | confirms |

Исследование: [Sybil/revoke](ca3a4374-c4bf-47e4-9316-59f91f91ba63) · [metadata/partition](46990499-6e2c-46c9-a176-2d2a3cf60fa3).

---

## As-is

### Sybil

- Контроль = enrollment. Default **`legacy` → сразу trusted** (открытый Sybil).
- `strict`/`hybrid` + admin secret = ручной gate.
- Нет PoW, stake, Trust Score history, L1 Observed.

### Revocation

- Admin: suspend / compromise / reinstate (suspend only) / approve.
- Catalog + heartbeat режут data-plane selection.
- **`compromised` sticky:** approve запрещён; восстановление — только через `POST /admin/registry/nodes/{node_id}/re-enroll` (Post-R5, сбрасывает в `pending` + новый `enrollment_secret`, ручной approve после).
- Mesh notify на revoke **нет**.

### Malicious relay

- Retry других relay + health ranking.
- Version quarantine (CVE) — не про honesty.
- **Нет** reputation / punishment / fraud proofs.

### Metadata

| Оператор | Видит |
|----------|--------|
| Home | users, participants, timing, sizes, online |
| Relay | hops, sizes, timing; LIVE часто `participant_user_ids` в meta |
| Discovery | user→home, resolve graph, node catalog |
| Gateway | invites / bootstrap |

Plaintext сообщений — нет (E2EE).

### Partition / no Bootstrap

- Gateway/Discovery = SPOF для join и remote resolve (R0/R1).
- Local same-Home чат может жить без Discovery.
- EU↔Asia / автономная сеть без Bootstrap — **не в коде**.

---

## Confirms

- 0302 корректно: Relay/Discovery метаданные — принятый риск v1.
- Enrollment statuses покрывают базовый revoke (частично).
- Цель «сеть без Bootstrap» = ADR-0006 roadmap, не LIVE.

---

## Gaps

| Gap | Влияние | Нужно |
|-----|---------|-------|
| `legacy` default | Sybil trivial | Ops: `strict` на проде; 0305 политика |
| ~~Нет re-enroll после compromise~~ | ~~Операционный тупик~~ | ✅ LIVE: `POST /admin/registry/nodes/{node_id}/re-enroll` |
| Нет relay reputation | Злой trusted relay живёт до ручного revoke | 0305 score; код позже |
| Relay видит participants | Лишние метаданные | **частично:** hop-scoped `participant_user_ids` (только sender+targets на этот Home) |
| Нет partition design в коде | Cross-region = fail | 0305 сценарии; multi-Discovery |
| Нет life-without-Gateway | Цель Guideline не выполнена | фазы B–D в 0305 |

---

## Что ломается

| Сценарий | Поведение |
|----------|-----------|
| 1000 fake nodes + `legacy` | Все trusted в каталоге → могут стать relay |
| Compromise | Нода навсегда вне approve-path, **если не** вызван `re-enroll` (Post-R5) |
| Злой relay drop | Sender best-effort; silent loss (R3) |
| Discovery down | Remote delivery/resolve стоп |
| Gateway down | Новые клиенты не входят |

---

## Feedback в T1

1. Зафиксировать Sybil/revoke/relay/metadata/partition/Bootstrap на бумаге (**0305**).
2. Guideline Part III → «спроектировано на бумаге», не «не обсуждалось».
3. Post-R5 приоритеты: `strict` default ops, re-enroll, durable outbox (R3), multi-Discovery (partition), client backup bootstrap URLs.
