# 0205. Node Record

## Статус
Draft (R1) — семантика to-be; wire LIVE = Discovery JSON (`mvp-json`).  
Сверка: [`docs/reality/R1-node-bootstrap.md`](../../docs/reality/R1-node-bootstrap.md).  
Roadmap: [`docs/DEVELOPMENT-ROADMAP.md`](../../docs/DEVELOPMENT-ROADMAP.md).

## Назначение
Каноническая запись о ноде в Control Plane (Discovery).  
Не путать с User Record и с Packet data plane.

## Bootstrap vs Discovery

| Роль | Кто в LIVE | Функция |
|------|------------|---------|
| **Bootstrap** | Gateway Node | Точка входа: invite, начальный routing (`/gateway/routing`). Не каталог доверия навсегда. |
| **Discovery** | Discovery Node | Control Plane: регистрация нод, trust lifecycle, каталог capabilities, resolve user→home. |
| **Data plane** | Home / Relay / Media / Storage / TURN | Доставка и медиа; не определяют trust. |

После входа сеть **должна** опираться на Discovery (и в будущем — на gossip соседей).  
Цель гайдлайна: Bootstrap перестаёт быть обязательным для уже участвующих нод (механизм — R5).

---

## Node Record v1 (логические поля)

| Поле | Тип (логично) | Обязательное | Смысл |
|------|---------------|--------------|-------|
| `NodeID` | string | да | Стабильный идентификатор ноды |
| `PublicKey` | bytes / key ref | да* | Ключ подписи ноды (*в LIVE: `signing_public_key`, часто optional) |
| `Roles` / `Capabilities` | string[] | да | `home`, `relay`, `media`, `storage`, `turn`, `gateway`, … |
| `Addresses` | URL[] | да | Как достучаться (`node_url` в LIVE — одно значение) |
| `CapabilitiesDetail` | map | нет | Лимиты CPU/RAM/clients (цель; в LIVE почти нет в Record) |
| `TrustLevel` | enum | да | См. mapping L0–L5 ниже |
| `Version` | string | да | `software_version` (+ опционально `build_hash`) |
| `Expires` | timestamp | нет* | TTL записи (*в LIVE нет; heartbeat заменяет) |
| `ValidatorSignatures` | sig[] | нет* | Подписи валидаторов (*в LIVE нет; approve оператором) |
| `ClusterID` | string | да (MVP) | Изоляция кластера (`default`) |
| `Attestation` | object | нет | `build_hash`, `tls_cert_fingerprint`, `release_signature`, `attestation_status` |

Поля **только control plane** (не обязаны быть в публичном Record):  
`node_token_hash`, `enrollment_secret_hash`, `approved_by`, `suspension_reason`, …

---

## Mapping: Guideline Trust Levels ↔ LIVE `trust_status`

Две оси не смешивать (ADR-0009): **доверие** vs **reachability** (`online`/`offline` по heartbeat).

| Guideline | Смысл (to-be) | LIVE `trust_status` | Примечание |
|-----------|---------------|---------------------|------------|
| **L0 Unknown** | Только что появилась / не классифицирована | `unknown` или `pending` | В `strict`: новая = `pending`. В `legacy`: сразу `trusted` (L0 пропускается) |
| **L1 Observed** | Видна, накоплена минимальная история | — | **Нет отдельного статуса**; ближайшее — `pending` + heartbeat history (не моделируется) |
| **L2 Active** | Участвует в data plane под контролем | `trusted` + `reachability=online` | Trust + online вместе ≈ L2 |
| **L3 Trusted Relay** | Доверена для relay | `trusted` + capability `relay` | Роль в `capabilities[]`, не отдельный trust enum |
| **L4 Validator** | Участвует в подтверждении записей | — | **Нет** в MVP |
| **L5 Root Authority** | Bootstrap / корневой оператор | Операторы Gateway/Discovery + admin approve | Не поле Record; роль инфраструктуры |

Операционные статусы LIVE **вне лестницы L0–L5**:

| `trust_status` | Смысл |
|----------------|--------|
| `suspended` | Временный отзыв |
| `compromised` | Компрометация; не reinstate без явной политики (сейчас approve с compromised запрещён) |

**Решение R1 (документальное):** не мигрируем код на L0–L5 enum.  
Канон для спек to-be — уровни L0–L5; канон для LIVE wire — `trust_status` + capabilities + reachability.  
Таблица выше — обязательный мост до Post-R5.

---

## Соответствие LIVE JSON (Discovery)

Источник: `project/services/discovery-node/app/schemas.py` → `RegisterNodeCapability` / `NodeCapabilityResponse`.

| Node Record v1 | LIVE поле | Есть? |
|----------------|-----------|-------|
| NodeID | `node_id` | да |
| PublicKey | `signing_public_key` | optional |
| Roles | `capabilities[]` | да |
| Addresses | `node_url` | да (одно) |
| TrustLevel | `trust_status` (+ reachability) | да (другая модель) |
| Version | `software_version`, `build_hash` | да |
| Expires | — | нет (heartbeat) |
| ValidatorSignatures | — | нет (admin approve) |
| ClusterID | `cluster_id` | да |
| Attestation | `build_hash`, `tls_cert_fingerprint`, `release_signature`, `attestation_*` | да |
| Capacity / Health in Record | `health_status` (probe) | частично; Capacity Score — нет |

Регистрация: `POST` registry node capability (см. `0604_DISCOVERY_NODE.md`, ADR-0009).  
Публичный каталог: только `trust_status=trusted`.

---

## Целевые дополнения (не блокер R1, backlog R2+)

1. `Expires` или явный TTL кэша Record у клиентов/нод.
2. Много адресов (multi-homing).
3. Подписи валидаторов вместо единственного admin approve (L4).
4. Публикация Capacity/Health score в Record для балансировки.
5. Явный enum TrustLevel **или** стабильный mapping API (без ломки federation).

## Связанные документы

- [ADR-0006](ADR/0006-staged-decentralization-bootstrap-authority.md)
- [ADR-0009](ADR/0009-node-enrollment.md)
- [ADR-0010](ADR/0010-node-attestation-and-gateway.md)
- [0604_DISCOVERY_NODE.md](0604_DISCOVERY_NODE.md)
- [0606_GATEWAY_NODE.md](0606_GATEWAY_NODE.md)
