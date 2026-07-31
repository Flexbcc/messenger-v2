# OUO Server Protocol Guideline v0.3

Техническое ТЗ (не набор идей).  
Сверка с LIVE-кодом: `project/` + клиент.  
_Зафиксировано: 2026-07-22_

Связано: [`AI-HANDOFF.md`](AI-HANDOFF.md) · [`STRUCTURE.md`](STRUCTURE.md) · `project/spec/` (0200–0203, ADR-0006…0010)

---

## Как читать

| Метка | Смысл |
|-------|--------|
| **A** | Принято в гайдлайне — больше не обсуждаем принцип |
| **U** | Требует уточнения / формальной спецификации |
| **N** | Практически не спроектировано |
| **✓ / ◐ / ✗** | Соответствие текущей реализации (MVP) |

Оценка гайдлайна: концепция **~70–80%**. Реализация MVP — **частичный срез** (централизованный кластер MAIN/WORKER), не полная mesh-сеть.

---

# Часть I — Принято (не обсуждаем)

## 1. Общая архитектура — A

- нет единого сервера сообщений как «облака»;
- сеть из независимых нод с id + ключами;
- нода сама балансирует нагрузку;
- клиенты могут менять ноды;
- маршруты динамические;
- сообщения E2EE;
- медиа принадлежит пользователю, не сети.

| Реализация сейчас | |
|-------------------|--|
| Независимые роли (home/media/discovery/gateway/relay/turn) | ✓ |
| E2EE в клиенте (Signal) | ✓ |
| Медиа → media-node / storage-app / S3 policy | ◐ |
| Полностью независимые операторы + свободная смена Home | ◐ (invite/bootstrap есть; «свободный mesh» нет) |
| Динамические multi-hop маршруты как в гайдлайне | ✗ (есть federation home→home + relay fallback) |

## 2. Bootstrap сети — A

Новая нода: ключи → Bootstrap → список нод/ключи/доверие/роли/версия → проверка → статус входа.  
Bootstrap только точка входа.

| Сейчас | |
|--------|--|
| Gateway invite + `/gateway/routing` bootstrap для **клиента** | ✓ |
| Discovery enrollment для **нод** (ADR-0009) | ✓ |
| Статус L0 как в гайдлайне | ✗ (у нас `trust_status`: pending/trusted/…) |
| Сеть полностью без Bootstrap после старта | ◐ (Discovery/Gateway всё ещё critical path) |

## 3. Система доверия — A (почти)

Trust / Health / Capacity + история; уровни L0…L5.

| Сейчас | |
|--------|--|
| `trust_status` + reachability (две оси, ADR-0009) | ✓ |
| Health score на home (monitor) | ◐ |
| Capacity / лимиты в env и admin | ◐ |
| История 7/30 дней, полный Trust Score | ✗ |
| Уровни L0–L5 как enum | ✗ (упрощённая модель pending/trusted/suspended/compromised) |

## 4. Метрики ноды — A

Нода сама задаёт лимиты и публикует состояние.

| Сейчас | |
|--------|--|
| `/health`, monitor metrics, env capacity | ◐ |
| Публикация capacity в каталог Discovery для балансировки | ◐ слабо |
| Автобалансировка клиентов по метрикам сети | ✗ |

## 5. Discovery — A (идея)

Доверенные / известные / соседние / резервные; Bootstrap только старт.

| Сейчас | |
|--------|--|
| Discovery реестр + heartbeat + trust filter | ✓ |
| Gossip / соседские списки / резервные наборы | ✗ |

## 6. Идентификация пользователей — A

QR → id + pubkey + служебное → обмен ключами.

| Сейчас | |
|--------|--|
| Profile QR / join invite QR | ◐ |
| Полный identity handshake по QR как единственный приватный онбординг | ◐ (есть password login MVP + QR) |

## 7. Поиск пользователей — A

QR / публичный (opt-in) / локальная нода (корпоратив).

| Сейчас | |
|--------|--|
| Публикация username / discoverability в profile_settings | ◐ |
| Корп. «только своя инфраструктура» | ◐ (один cluster_id) |
| Полностью private-only по умолчанию | ◐ |

## 8. Маршрутизация — A (концепция)

Клиент знает current/previous/backup; смена ноды → служебное сообщение.

| Сейчас | |
|--------|--|
| Discovery resolve user → home | ✓ |
| Federation + relay fallback | ◐ |
| Клиентский журнал маршрутов + backup path + notify | ✗ |

## 9. Сообщения — A

E2EE, очередь, ACK, retry; промежуточные не читают plaintext.

| Сейчас | |
|--------|--|
| E2EE клиент, REST/WS на Home | ✓ |
| Delivery status / retry куски | ◐ |
| Единый packet lifecycle как в спеке 0202 | ◐ (спека есть, wire ≠ protobuf packets) |

## 10. Медиа — A

Устройство → Home → своё S3 → временное. Сеть не хранит навсегда.

| Сейчас | |
|--------|--|
| Media node + storage policy + storage-app PPC | ◐ близко |
| Жёсткий приоритет как в гайдлайне end-to-end | ◐ |

## 11. Несколько устройств — A

Все устройства одного user; sync; P2P при возможности.

| Сейчас | |
|--------|--|
| Multi-device login / devices API | ◐ |
| Полный sync журнала + conflict resolution | ✗ |
| P2P sync устройств | ✗ |

## 12. Звонки — A

Отдельные маршруты от сообщений; смена маршрута в звонке.

| Сейчас | |
|--------|--|
| WebRTC + TURN + signaling через home | ◐ |
| Динамическая смена relay mid-call как продукт | ✗ |

---

# Часть II — Требует доработки (U)

Приоритет следующего этапа (из гайдлайна) — **в этом порядке**:

| # | Тема | Статус спеки в репо | Статус кода |
|---|------|---------------------|-------------|
| U1 | **Handshake** (пакеты, таймауты, ошибки, версии, ciphers) | Черновик `0200_PROTOCOL.md` | ✗ формальный wire handshake |
| U2 | **Node Record** (поля, подписи валидаторов, expires) | Частично Discovery schemas | ◐ JSON registration ≠ финальный Record |
| U3 | **Формат пакетов** (header/payload/sig/TTL/…) | Черновик `0201_PACKETS.md` | ✗ (сейчас HTTP/JSON + WS) |
| U4 | **Жизненный цикл сообщения** (+ ACK + очистка очередей) | `0202_DELIVERY.md` | ◐ |
| U5 | **Очереди** (где, TTL, delete after ACK) | частично | ◐ |
| U6 | **Синхронизация устройств** | слабо | ✗ |
| U7 | **Большие файлы** (resume, stream, integrity, dedup) | media docs | ◐ upload |
| U8 | **Голосовые вызовы** (signaling, NAT, TURN, restore) | ADR-0008, 0303 | ◐ |
| U9 | **Обновление маршрутов** (TTL, version, rollback) | `0203_ROUTING.md` | ✗ |
| U10 | **Отзыв нод** (compromise, block, re-key) | ADR-0009 statuses | ◐ (suspend/compromised в API) |
| U11 | **Обновление протокола** (compat, force upgrade) | `0204_VERSIONING.md` | ✗ enforced |

---

# Часть III — Безопасность сети (спроектировано на бумаге, R5)

Детали: [`project/spec/0305_NETWORK_SECURITY_NOTES.md`](../project/spec/0305_NETWORK_SECURITY_NOTES.md) · сверка [`reality/R5-security-as-is.md`](reality/R5-security-as-is.md).

| Тема | На бумаге (R5) | LIVE |
|------|----------------|------|
| **Sybil** | Admission L0→L3 + Observation; `legacy` запрещён как prod-policy | Только enrollment; default `legacy` открыт |
| **Метаданные** | v1 = E2EE content; path/time/volume **не** анонимны; mixnet out of scope | Home/Relay/Discovery видят граф/timing; relay meta слишком богатая |
| **Злонамеренный Relay** | Multi-path retry + demote score + operator revoke; без fraud proofs в v1 | Retry/health есть; reputation нет |
| **Partition (EU↔ASIA)** | Intra OK; cross → outbox; multi-Discovery per region | Не реализовано; один Discovery SPOF |
| **Без Bootstrap** | Фазы A→D: от cluster MVP к peer invite + validators | Gateway/Discovery обязательны для join |

Реализация механизмов — **Post-R5**, отдельное решение.


---

# Ближайшие задачи (рабочий backlog)

Актуальный порядок работ и два трека (Protocol + Reality):  
**[`DEVELOPMENT-ROADMAP.md`](DEVELOPMENT-ROADMAP.md)** (фазы R0–R5).  
Ниже — краткая проекция Guideline → roadmap (не дублировать статусы вручную).

| Guideline | Roadmap |
|-----------|---------|
| P0 Guideline + gap | R0 done |
| Node Record + trust mapping | **R1 done** → [`0205_NODE_RECORD.md`](../project/spec/0205_NODE_RECORD.md) |
| Packet / Handshake (`mvp-json`) | **R2 done** → [`0200`](../project/spec/0200_PROTOCOL.md) / [`0201`](../project/spec/0201_PACKETS.md) |
| Lifecycle + очереди | **R3 done** → [`0202`](../project/spec/0202_DELIVERY.md) |
| Маршрутизация / смена ноды | **R4 done** → [`0203`](../project/spec/0203_ROUTING.md) |
| Sybil / metadata / revocation / partition | **R5 done** → [`0305`](../project/spec/0305_NETWORK_SECURITY_NOTES.md) |
| Server implementation | Post-R5 (отдельное решение) |

Не «писать весь сервер заново», а закрыть инженерную спецификацию **со сверкой reality-note**, затем точечно подтягивать MVP.

---

# Сводка соответствия

| Блок гайдлайна | Концепция | Код MVP |
|----------------|-----------|---------|
| Архитектура нод + E2EE + медиа-владение | ✔ | ◐–✓ |
| Bootstrap / Discovery / enrollment | ✔ | ✓ упрощённо |
| Trust L0–L5 + история | ✔ почти | ◐ другая модель |
| Метрики / capacity | ✔ | ◐ |
| Маршрутизация / пакеты / handshake | ✔ идея | ✗–◐ (спеки-черновики, wire другой) |
| Multi-device sync / partition / Sybil | слабо | ✗ |

**Вывод:** принципы гайдлайна **согласованы** с `project/spec` и ADR.  
**Расхождение:** LIVE — это **кластерный MVP** (Gateway+Discovery+Home) на HTTP/JSON, а гайдлайн описывает **целевой mesh-протокол**. Следующий шаг — P1 (формализовать Record/Packet/Handshake и явно пометить MVP transport profile), не переписывать ноды вслепую.

---

## Где править дальше

| Документ | Роль |
|----------|------|
| Этот файл | Guideline + gap |
| [`DEVELOPMENT-ROADMAP.md`](DEVELOPMENT-ROADMAP.md) | План R0–R5, два трека |
| [`reality/`](reality/) | As-is сверка (T2) |
| `project/spec/0200–0205` | Детализация протокола |
| `project/spec/ADR/0009–0010` | Enrollment / attestation |
| `docs/AI-HANDOFF.md` | Что LIVE сейчас |

При работе по протоколу: сначала **спека (T1) + reality-note (T2)**, потом код; не наоборот.
