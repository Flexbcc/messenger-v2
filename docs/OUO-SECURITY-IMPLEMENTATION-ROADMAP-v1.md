# OUO v1 — implementation roadmap и gap-анализ

## Назначение

Документ переводит целевую
[`OUO-SECURITY-ARCHITECTURE-v1.md`](OUO-SECURITY-ARCHITECTURE-v1.md) в порядок
реализации и отделяет существующий messenger-v2 от целевой архитектуры.

Snapshot аудита:

- исходный аудит: 2026-08-19;
- текущий development pass: 2026-08-23;
- commit: `3ddc867cd642a6d67e9328025964b5daf45bfb25`;
- локальный `main` совпадает с `github/main`;
- текущий pass проверен только статически по требованию владельца; тесты и
  процессы после изменений не запускались;
- PVE2 прошёл read-only API audit 2026-08-23; создание новой VM ещё не
  выполнялось.

## Легенда

| Статус | Значение |
|---|---|
| `WORKS` | Код и явный runtime path существуют; production требует live test |
| `PARTIAL` | Есть часть механизма, но не достигнуты целевые security properties |
| `MISSING` | Реализации нет или есть только спецификация/скелет |
| `CONFLICT` | Текущая модель противоречит целевой и требует миграции |
| `OUT OF V1` | Код сохраняется, но не входит в critical path OUO v1 |

## Краткий вывод

Сейчас проект — cluster-MVP с центральным Discovery, HTTP/JSON federation и
серверным хранением зашифрованной истории. Он пригоден как baseline для Basic
Relay и failure tests, но пока не является целевым Secure Text MVP.

Главные блокеры P0:

1. Нет Identity Root/self-certifying UserID и RecoveryPolicy.
2. Device keys и Signal state частично хранятся в SharedPreferences.
3. Self-certifying Node Identity и serial-specific quorum revocation работают
   в enforce local/secure profiles, но legacy alias ещё остаётся primary lookup
   key, а Node Root transition не реализован.
4. CapabilityCertificate является enforcement source; secure compose теперь
   отдельный fail-closed profile, а базовый compose оставлен migration-only.
5. Discovery применяет quorum TrustRecord, хранит signed external observations,
   синхронизирует AuthorityCheckpoint gossip и замораживает governance при
   equivocation; пользовательские records пока публикуются в D1/D2/D3 отдельно.
6. User-signed BootstrapRecord уже хранится Discovery без переподписания, но
   legacy `user_records` и клиентская миграция остаются.
7. RouteDescriptor проверяется и кэшируется D1/D2/D3; Home runtime выполняет
   quorum resolve, persistent anti-rollback и active/future selection. Передача
   descriptor внутри E2EE остаётся endpoint-задачей.
8. Secure compose override включает signed режим, однако базовый compose
   намеренно оставлен backward-compatible до завершения миграции.

## Фактическая карта текущих сервисов

| Компонент | Статус | Что работает | Главный gap |
|---|---|---|---|
| Discovery | `WORKS/PARTIAL` | own Node Identity, register/heartbeat, identity/advertisement/capability enforcement, BootstrapRecord, RouteDescriptor cache, Trust Ledger, challenge evidence, AuthorityCheckpoint chain и authenticated pull-gossip | legacy user route, deployment diversity/recovery ceremony и admin path ещё central |
| Gateway | `WORKS/PARTIAL` | invite, routing/catalog, bootstrap, optional mTLS | central bootstrap SPOF |
| Home | `WORKS/PARTIAL` | auth, devices, conversations, WS, federation, outbox, ACK, SQLite | server хранит graph/history; нет target Identity/Route model |
| Relay | `WORKS/PARTIAL` | unified HTTP/WSS adapter, binary batches, per-hop replay, certified quotas, signed target admission, retry и backpressure bounds | видимый target URL/metadata, нет onion/mix |
| Storage | `WORKS/PARTIAL` | opaque hashed mailbox capability, fixed cells, TTL/ACK, disk budget и quorum replication client | endpoint activation и padded polling |
| Media | `WORKS/OUT OF V1` | encrypted blobs и configurable backend | media исключена из OUO v1 |
| TURN API + coturn | `PARTIAL`, P3 | credentials и compose coturn | live NAT/relay-only/E2EE voice tests не подтверждены |
| Push proxy | `PARTIAL` | data-only/content-free wake-up paths | metadata и endpoint policy требуют тестов |

## P0 — User Identity, Recovery и endpoint

| Требование | Статус | Факт сейчас | Действие |
|---|---|---|---|
| Identity Root | `MISSING` | `User.id` — UUID Home DB | key hierarchy и self-certifying UserID |
| Отдельные Device Keys | `PARTIAL` | auth Ed25519 и Signal identity разделены | Device Certificate от Identity Root |
| Device add | `PARTIAL` | QR link подтверждает существующий JWT/device | signed versioned Identity state |
| Device revoke | `PARTIAL` | Device удаляется, WS/JWT отзываются, KT event пишется | rekey и signed update контактам |
| RecoveryPolicy | `MISSING` | есть export local identity backup | threshold recovery без server reset |
| IdentityTransition | `MISSING` | versioned root transition отсутствует | object + proofs + anti-rollback |
| Key Transparency | `PARTIAL` | Home хранит hash-linked events | independently verifiable consistency |
| Hardware-backed keys | `CONFLICT` | auth seed и Signal state в SharedPreferences | Keychain/Keystore/TPM adapter |
| Encrypted local DB | `PARTIAL` | message payload шифрует DeviceCrypto | проверить key storage и metadata leaks |
| JWT secure storage | `CONFLICT` | access token в SharedPreferences | secure storage и short-lived policy |
| Recovery backup | `PARTIAL` | export включает private seeds/storage key | source encryption, KDF, integrity, version |

## P0 — E2EE

| Требование | Статус | Факт сейчас | Действие |
|---|---|---|---|
| 1:1 ratchet | `WORKS/PARTIAL` | `libsignal_protocol_dart`, prekeys, persistent sessions | audit и MITM/replay/loss/out-of-order tests |
| Multi-device E2EE | `PARTIAL` | per-device envelopes и prekey endpoints | доказать независимые sessions и revoke/rekey |
| Groups | `WORKS/PARTIAL` | sender-key path существует | после 1:1 решить MLS/стандартную схему |
| Server has no plaintext | `PARTIAL` | Home хранит ciphertext | negative logging/crash/backup tests |
| Forward secrecy/PCS | `PARTIAL` | свойства Signal используются | persistence/session recreation tests |

## P0 — Node Identity и protocol objects

| Требование | Статус | Факт сейчас | Действие |
|---|---|---|---|
| Node Root Key | `WORKS/PARTIAL` | persistent отдельный Ed25519 Root создаётся всеми node services | вынести Root offline/HSM policy перед production |
| Self-certifying NodeID | `WORKS/PARTIAL` | полный SHA-256 NodeID проверяется и хранится рядом с legacy alias | мигрировать lookup с alias на NodeID |
| Operational Certificate | `WORKS/PARTIAL` | root-signed cert ≤7d, explicit rotation, atomic sidecar chain, opt-in registration/heartbeat renewal, D1/D2/D3 high-watermark gossip и quorum serial revocation; portable observer live enforce | production migration, validator ceremony и Node Root transition |
| Key separation | `PARTIAL` | signing и Home X25519 key разделены | domain separation всех ролей |
| Signed federation | `WORKS/PARTIAL` | headers + full-envelope binding, timestamp, nonce, forwarding identity | убрать legacy mode после миграции |
| Replay protection | `WORKS/PARTIAL` | persistent nonce DB, strict bounded link sequence, per-hop cell/envelope replay spaces | будущий onion-layer replay и long-window suite |
| Versioned objects | `PARTIAL` | Identity, cert, advertisement, capability, trust, bootstrap, route versioned/fail-closed | распространить правило на все legacy API |
| Anti-downgrade | `PARTIAL` | Route/Authority/Advertisement epochs и distributed Operational Credential high-watermark сохраняются | protocol/update high-watermarks |
| Crypto agility | `MISSING` | нет signed suite policy | limited suite IDs и migration |

## P0 — Trust и Capability

| Требование | Статус | Факт сейчас | Действие |
|---|---|---|---|
| L0–L5 | `PARTIAL` | БД имеет level, API фактически L0–L2 | полный lifecycle без bandwidth coupling |
| Level != Capability | `WORKS/PARTIAL` | secure Discovery/federation используют quorum certificate; heartbeat renewal, hash-chain, same-epoch equivocation и expiry filtering реализованы | production issuance/revocation ceremony |
| L0 restrictions | `WORKS/PARTIAL` | secure profile fail-closed запрещает self-declared Relay/Storage/Discovery; L0 Home сохраняет только собственный service path | убрать legacy/report после migration |
| External evidence | `WORKS/PARTIAL` | signed observations проверяются/хранятся Discovery с expiry, quota и replay constraints | multi-observer aggregation/diversity |
| Synthetic challenges | `WORKS/PARTIAL` | real challenges; quorum RandomnessCheckpoint, proposal-only scheduler, enforce observer recomputation и D1/D2/D3 assignment/ACK/observation lifecycle | automatic cadence, missed-job policy, threshold-VRF |
| Reliability vs Security | `PARTIAL` | bounded Reliability snapshot отделён от Trust/security decision и не auto-promote | отдельная Security Reputation и signed scoring policy |
| Committee selection | `WORKS/PARTIAL` | deterministic selection и quorum-signed chained randomness snapshot реализованы | reviewed threshold-VRF/external beacon и anti-grinding |
| Quorum attestations | `WORKS/PARTIAL` | 5/7 validation подключена к TrustRecord, ChallengeAssignment и AuthorityCheckpoint transitions; D1/D2/D3 gossip convergence тестируется | recovery ceremony |
| Trust Ledger | `WORKS/PARTIAL` | signed hash chain, SQLite store, conflict evidence; exact historical authority validation и bounded pull-replication D1/D2/D3; late subject reconciliation | production TLS/operator diversity и distributed decision scheduler |
| Degradation/revocation | `WORKS/PARTIAL` | quorum suspension→reinstatement и terminal revocation, shared control-plane admission; offline только evidence | Root/identity recovery остаётся fail-closed по `0239` |
| Sybil resistance | `PARTIAL` | 100/1k/10k unsigned L0 escalation simulation даёт 0 accepted | diversity/challenges/history model |

## P0 — Distributed Discovery и Routes

| Требование | Статус | Факт сейчас | Действие |
|---|---|---|---|
| 3 independent Discovery | `PARTIAL` | D1/D2/D3 с независимыми DB/key проходят loopback test | production placement/operator diversity |
| Signed BootstrapRecord | `WORKS/PARTIAL` | user-signed self-certifying record хранится без re-sign; rollback/equivocation tests | клиентская публикация и отказ от legacy API |
| Signed NodeAdvertisement | `WORKS/PARTIAL` | secure registration/heartbeat fail-closed; same-epoch equivocation, expiry filtering и bounded D1/D2/D3 observation gossip | production source/operator diversity и reachability challenges |
| RouteDescriptor | `WORKS/PARTIAL` | signed chain, D1/D2/D3 cache, Home quorum runtime, current/next/next+1 и disk high-watermark | E2EE distribution до контактов и ingress data protocol |
| Home != Ingress | `MISSING` | target Home URL виден | multiple temporary ingress |
| Discovery outage continuity | `WORKS/PARTIAL` | existing Home data plane и D2/D3 bootstrap фактически работают при D1 down | client RouteDescriptor recovery |
| Safe mode | `WORKS/PARTIAL` | persistent guard; signed multi-source checkpoint gossip, quorum equivocation freeze и 3-of-5 offline recovery apply; data plane остаётся | multi-Discovery recovery drill/external review |

## P1 — распределённая сеть

| Требование | Статус | Факт сейчас | Действие |
|---|---|---|---|
| Basic Relay | `WORKS/PARTIAL` | HTTP fallback + authenticated persistent WSS batches; session reuse/reconnect; replay DB; global/per-peer/frame/batch/idle/processing bounds | TLS termination, Mix queue/reroute backpressure и peer rotation |
| Durable retry | `WORKS` | SQLite outbox, exponential backoff | recovery/load/idempotency/expiry tests |
| Delivery ACK | `WORKS/PARTIAL` | signed semantic ACK проходит реальный network path | разделить transport/mailbox/e2e ACK states |
| Offline mailbox | `WORKS/PARTIAL` | opaque token/fixed-cell store-fetch-ACK, quotas, idempotency; live endpoint-side decrypt | Home/client activation, polling и redundancy |
| Mailbox redundancy | `WORKS/PARTIAL` | parallel replication client, write quorum, merged fetch и per-replica ACK | включение endpoint mailbox lifecycle |
| Active peer set | `WORKS/PARTIAL` | multi-source signed runtime, private persistent seed, 2 guards + 4 rotating + 2 reserves и in-memory expiry fail-closed | production D1/D2/D3 provisioning |
| Peer diversity | `PARTIAL` | min-two-source admission, hard group caps и fail-degraded selector tests | signed advertisement aggregation/operator mapping |
| Route rotation/recovery | `WORKS/PARTIAL` | Home выбирает active epoch и два future через multi-Discovery quorum | endpoint publication/rotation scheduler |
| Admission control | `WORKS/PARTIAL` | bounded anonymous bucket, strict cheap headers, trust-before-body/crypto, 1 MiB bounded stream, bounded trusted buckets, negative-cache single-flight, WSS budgets | reverse-proxy address/connection validation, external load tests/adaptive PoW |
| Contact Capability | `WORKS/PARTIAL` | endpoint-signed opaque mailbox capability, strict initial-text permission, quota/expiry; bounded adaptive anonymous PoW core | Home endpoint integration и blocking/rotation lifecycle |

Secure Federation request authentication теперь использует quorum peer-view
нескольких Discovery, а не signing key/capabilities из одного registry. Legacy
single-source cache сохранён только вне secure profile.

## P2 — Privacy Transport

`PARTIAL`: strict binary batch, persistent Relay WebSocket adapter, persistent
link replay protection и XChaCha20-Poly1305 fixed-size padded cell primitive
реализованы. Добавлены opaque ingress contract, отдельный root-signed X25519
Transport Certificate, локальный diversity-aware route builder, bounded Mix
Pool, jitter и budgeted cover scheduler. Изменения текущего прохода не
запускались и не тестировались по прямому указанию владельца.

Остаются `MISSING`:

- QUIC adapter;
- aggregation policy и включение fixed cells в межнодовый runtime;
- endpoint-side packet construction и отправка первого multi-hop ingress;
- рассмотренный Sphinx-like provider (граница есть, без provider fail closed);
- multipath runtime activation и рассмотренный K-of-N codec provider (planner
  и bounded async Rust-sidecar boundary реализованы);
- adaptive cover primitive реализован; provider-backed wiring отсутствует.
  Storage padded mailbox response реализован; endpoint periodic scheduler
  отсутствует;
- traffic-correlation simulator и quantitative acceptance.

Relay всё ещё видит target Home URL и linkable envelope metadata. WSS adapter
устраняет one-connection-per-message overhead, но это Basic Transport, не Mix.

Отдельный Relay Mix ingress, delayed next-hop runtime и destination Home
final-mailbox handler со Storage write quorum реализованы локально; полный path
остаётся незавершённым до reviewed Sphinx provider. Basic Relay metadata
statement выше относится к старому `/relay/forward` path.

Relay next-hop resolution требует одинаковый security commitment из quorum
независимых Discovery и повторно валидирует Transport Certificate локально;
single Discovery больше не определяет endpoint Mix hop. Quorum result имеет
bounded single-flight cache, ограниченный ближайшим expiry всех подписанных
node credentials. Onion expiry аутентифицирован provider layer и не может
продлеваться Relay на каждом переходе.

## P3 — Voice

| Требование | Статус | Факт сейчас | Действие |
|---|---|---|---|
| E2EE signaling | `PARTIAL` | call signals идут как messages | protocol/replay/session tests |
| P2P WebRTC | `PARTIAL` | клиентский path существует | live cross-NAT/network-switch tests |
| TURN credentials | `WORKS/PARTIAL` | JWT, unique opaque HMAC credentials, bounded TTL, separated secrets | secret rotation ceremony |
| coturn relay | `PARTIAL` | compose/config есть | live public IP/NAT/UDP test |
| relay-only privacy | `WORKS/PARTIAL` | credential contract возвращает relay-only policy, coturn STUN health probe | client enforcement и live no-peer-IP verification |
| media E2EE claim | `PARTIAL` | WebRTC encryption expected | actual stack/key-separation review |

## P4 — Production hardening

| Требование | Статус | Факт сейчас | Действие |
|---|---|---|---|
| Threshold updates | `MISSING` | unsigned JSON manifest с legacy VPS URLs | TUF-like threshold metadata |
| Rollback protection | `MISSING` | `min_version` недостаточно | signed highest version/expiry/snapshot |
| Reproducible builds | `MISSING` | build scripts есть | pinned hermetic builders |
| Release transparency | `MISSING` | append-only log отсутствует | signed release records |
| Secret management | `PARTIAL` | secure compose override, bind-local defaults override, placeholder/permission validator | external secret manager и rotation drill |
| Logging minimization | `PARTIAL` | federation audit есть | field policy/redaction/retention tests |
| Encrypted backups | `MISSING/PARTIAL` | backup scripts есть | source encryption и restore drills |
| Fuzzing | `MISSING` | parser fuzz suite нет | all parsers + bounded allocation |
| Chaos | `PARTIAL` | settings chaos/smoke scripts | node kill/restart/partition/cert chaos |
| Attack simulator | `PARTIAL` | Trust/Sybil 100/1k/10k и committee capture model | network, eclipse, relay и traffic-observer scenarios |
| External audit | `MISSING` | audit evidence нет | gates A–E и updates |

## План действий

### Phase 0 — baseline и воспроизводимость

1. Локальный baseline: D1/D2/D3, 3 Home, Relay и Storage — `DONE` на loopback.
2. Secure compose profile (`strict`, `signed`, bind-local, без placeholder
   secrets) — `DONE` как конфигурация; production secrets ещё не создавались.
3. Delivery/failure/persistence tests с JSON summary и per-service logs — `DONE`.
4. Зафиксированный Python 3.11 test runtime — `DONE`; локальный system Python
   3.9 намеренно отклоняется runner-ом.
5. Threat-test catalog с IDs — `DONE` для текущего node scope.
6. PVE2 read-only audit — `DONE`: ресурсы, storage, bridge, ISO/templates и
   существующие guests инвентаризированы. Новая отдельная VM 107 и secure
   12-node package — `READY FOR EXPLICIT CREATE APPROVAL`; существующие VM/LXC
   не изменяются.

Exit: текущие tests зелёные в поддерживаемом runtime; 5–8 logical nodes проходят
baseline contract; есть latency/reliability report; legacy mode выключен.

### Phase A — User Identity, Recovery и 1:1 E2EE

1. Специфицировать Identity Root, UserID и Device Certificate.
2. Добавить versioned signed device state.
3. Перенести seeds, Signal state и JWT в secure storage abstraction.
4. Реализовать revoke с session rekey.
5. Реализовать RecoveryPolicy и IdentityTransition.
6. Добавить MITM/replay/order/loss/add/revoke/rollback/multi-device tests.
7. Провести внешний review E2EE integration.

Exit: DoD User Identity/E2EE; Home/Discovery не создают Identity/device и не
получают plaintext.

### Phase B — Node Identity, Capability и Trust

1. Node Root, NodeID и Operational Certificate — `DONE/PARTIAL`: lifecycle,
   registration и report-only Discovery binding работают; alias migration остаётся.
2. Rotation, expiry и Discovery registration anti-rollback — `DONE`;
   root-signed distributed high-watermark, D1/D2/D3 gossip и portable live
   enforce и atomic node-side chain helper — `DONE` локально;
   opt-in registration/heartbeat renewal wiring и quorum serial revocation —
   `DONE`; production migration и Node Root transition — `PENDING`.
3. Level и Capability разделены; report/enforce modes — `DONE` локально.
4. L0 infrastructure rights запрещены в enforce mode — `DONE`.
5. Capability Certificate и quotas — `DONE` как verifier/reference object.
6. External observations и action runner — `DONE`; Relay/Storage/Discovery lookup
   challenges проходят runtime. External-seed observer selection — `DONE` как
   primitive; quorum-signed ChallengeAssignment, Discovery persistence,
   portable Operational-Key pull, signed observer ACK и completion только через verified
   TrustObservation — `DONE`; immutable assignment и append-only signed ACK
   D1/D2/D3 replication — `DONE`; portable assignment-bound observation и
   completion replication — `DONE`; quorum RandomnessCheckpoint, D1/D2/D3
   convergence и proposal-only deterministic scheduler — `DONE`; automatic
   cadence, threshold-VRF и missed-job policy — `PENDING`.
7. Committee, quorum и Trust Ledger — `DONE/PARTIAL`: реальный Discovery
   endpoint применяет 5/7 promotion, 4/7 отклоняет и equivocation включает Safe Mode;
   previous-quorum AuthorityCheckpoint обновляет effective authority;
   signed pull-gossip и independent three-DB convergence — `DONE` локально.
8. Reliability/Security evidence разделены — `DONE` в schema.
9. Базовые quorum/Sybil invariants покрыты unit/property tests; Trust simulator
   проверяет 100/1k/10k L0 и committee capture. Полный network simulator — `PENDING`.

Exit: L0 не self-promote; 4/7 не заменяет 5/7; candidate не выбирает committee;
revoked/expired validator не голосует; unsigned capability не принимается.

### Phase C — Distributed Discovery и Route Protocol

1. D1/D2/D3 с независимыми keys/state — `DONE` в локальном восьмипроцессном test.
2. User-signed BootstrapRecord и signed NodeAdvertisement — `DONE/PARTIAL`;
   legacy API и report mode пока сохранены.
3. Independent verification — `DONE` библиотекой и тестом всех трёх Discovery.
4. RouteDescriptor current/next/next+1 chain, preload, persistent Discovery
   recovery cache и anti-rollback — `DONE` для infra; client E2EE distribution
   и endpoint activation — `PENDING`.
5. E2EE descriptor distribution.
6. Recovery через несколько Discovery.
7. Network-view comparison и persistent control-plane freeze — `DONE/PARTIAL`;
   AuthorityCheckpoint validation/persistence, authenticated gossip и
   threshold offline recovery path — `DONE` локально; внешний recovery drill
   остаётся.

Exit: outage всех Discovery не ломает established chat до expiry routes;
malicious Discovery не подменяет Identity/Route.

### Phase D — Basic Relay, peers и mailbox

1. Binary Basic Transport поверх persistent WSS adapter — `DONE` на Relay и Home send path.
2. Bounded admission, signed operational handshake, global/per-peer connection,
   frame/batch/idle/processing limits — `DONE` локально.
3. Relay session/batch endpoint и Home runtime adapter — `DONE`; HTTP сохранён
   как configurable fallback.
4. Guard/rotating/reserve peer selection — protocol core `DONE`; signed
   D1/D2/D3 observation gossip, persistent aggregation и selector-ready view
   `DONE` локально; runtime activation ждёт persistent local seed и deployment
   diversity data.
5. Opaque mailbox tokens и fixed encrypted cells — Storage API/foundation
   `DONE`; Home/client activation `PENDING`.
6. Mailbox redundancy.
7. Разделить transport/mailbox/e2e ACK.
8. Malicious Relay/Storage и restart/expiry/rotation tests.

Exit: Gate D и Secure Text MVP выполнены без Mix.

### Phase E — Mix Transport

Последовательно: fixed cells/padding -> multi-hop -> reviewed Sphinx-like layer
-> multipath -> K-of-N -> Mix Pool/backpressure -> jitter -> cover -> adaptive
cover/padded polling.

Каждый шаг сравнивается с baseline. Нужны delivery, latency, bandwidth, CPU/RAM
и attacker-correlation metrics.

### Phase F — Voice

Формализовать E2EE signaling; проверить P2P voice; подтвердить coturn за NAT;
реализовать relay-only privacy; проверить reconnect/network switch/key separation.

### Phase G — Public hostile network

Threshold/TUF updates, transparency, reproducible builds, DDoS admission,
Contact Capability, fuzzing, chaos, simulator 100/1k/10k, backup/recovery drills,
external audit и только доказуемые security claims.

## Ближайший исполнимый backlog

1. `INFRA-001`: PVE2 topology/resource audit и 12-node compose — `DONE` как
   план/конфигурация; создание VM 107, admin overlay и runtime validation —
   `WAITING FOR EXPLICIT CREATE APPROVAL`.
2. `BASE-001`: reproducible Python 3.11 tests — `DONE`.
3. `BASE-002`: secure compose profile — `DONE` (actual secrets только при deploy).
4. `BASE-003`: 3-Home federation/ACK/storage persistence test — `DONE`.
5. `BASE-004`: Discovery/Relay/Home outage matrix с логами — `DONE/PARTIAL`;
   certificate expiry и локальный control-plane outage/rejoin проверены;
   host/network-level partition ещё требует стенд.
6. `TRUST-001`: подключить Trust Ledger к promotion path — `DONE` локально.
7. `AUTH-001`: quorum AuthorityCheckpoint chain, signed D1/D2/D3 pull-gossip и
   3-of-5 offline AuthorityRecovery — `DONE` локально; внешний recovery drill —
   `PENDING`.
8. `ROUTE-001`: persistent highest epoch и D1/D2/D3 recovery cache — `DONE`
   локально; передача внутри E2EE/endpoint activation — `PENDING`.
9. `RELAY-001`: persistent WSS Transport Adapter — `DONE` на Relay endpoint и
   Home send path; production WSS требует TLS termination.
10. `PEER-001`: signed NodeAdvertisement observations, D1/D2/D3 pull-gossip,
    two-source aggregation и fail-closed equivocation — `DONE` локально;
    Home opt-in signed runtime, persistent local seed/guards и reserve fallback
    — `DONE` локально; production activation/diversity provisioning — `PENDING`.
11. `TRUST-002`: offline auto-degradation больше не обходит quorum: observe-only
    candidates по умолчанию, authoritative transition только TrustRecord —
    `DONE` локально.
12. `SIM-001`: peer eclipse scenarios поверх production selector — `DONE`
    локально для single-source 10k Sybil, single-operator cap и spoofed-diversity
    residual risk; network latency/traffic observer models — `PENDING`.
13. `IDENTITY-001`: federation request/payload identity переключается на
    self-certifying NodeID в secure enforce mode; alias остаётся migration-only
    — `DONE` локально.
14. `TRUST-003`: quorum TrustRecord pull-replication между D1/D2/D3, historical
    authority validation, conflict freeze и late-registration apply — `DONE`
    локально; production peer provisioning остаётся `PENDING`.
15. `DDOS-001`: malformed/unknown signed federation requests отклоняются до
    body read и crypto; declared/chunked body имеет hard limit — `DONE` локально;
    volumetric/reverse-proxy стенд остаётся `PENDING`.
16. `ASSIGN-001`: quorum ChallengeAssignment получает bounded historical-
    authority pull replication D1/D2/D3 и conflict freeze — `DONE` локально;
    переносимые Operational-Key pull/ACK, parameter binding и nonce replay
    protection, append-only signed ACK и assignment-bound observation/completion
    replication, quorum randomness checkpoint и deterministic proposal
    enforcement — `DONE` локально; automatic cadence/threshold-VRF/missed-job
    policy — `PENDING`.
17. `IDENTITY-002`: root-signed monotonic Operational Credential state,
    append-only D1/D2/D3 pull-gossip, same-epoch conflict freeze и отдельные
    live/historical validation rules и atomic node-side chain maintenance —
    `DONE` локально; production opt-in migration — `PENDING`.
18. `IDENTITY-003`: отдельный quorum-signed отзыв одного Operational
    Certificate serial/key, append-only D1/D2/D3 gossip, event-time проверка
    исторических ACK/TrustObservation и live 403 без сброса Level/Capability —
    `DONE` локально; production validator ceremony и Root transition —
    `PENDING`.
19. `TRUST-004`: shared node-wide deny admission, terminal revocation state,
    event-time historical exception и запрет legacy admin override в enforce —
    `DONE` локально; explicit quorum suspension→reinstatement — также `DONE`.
20. `IDENTITY-004`: Root compromise fail-closed boundary — старый NodeID
    terminal revoked, новый Root получает новый L0 NodeID без alias/Level/
    Capability transfer — `DONE` локально; precommitted NodeRecoveryPolicy и
    continuity transition — `PENDING`.
21. `NODE-ADV-005`: secure heartbeat теперь обязан обновлять подписанный
    краткоживущий Advertisement; одинаковый epoch с иным content отклоняется,
    а просроченный record исключается из обычного node/peer listing — `DONE`
    unit/integration и подтверждено обновлённым 8-process cluster test.
22. `CONFIG-002`: secure-env preflight проверяет зависимости Capability,
    TrustLedger и Authority gossip: enforce требует соответствующий Authority
    State, а distributed Trust enforce — два peer origin для Authority/Trust
    pull-gossip — `DONE` локально.
23. `CAP-005`: secure Compose переведён с report на
    `CAPABILITY_CERTIFICATE_MODE=enforce` и
    `FEDERATION_CAPABILITY_MODE=enforce`; каждая infrastructure role читает
    отдельный provisioned certificate из своего `/data`, а L0 Home не получает
    инфраструктурные права самодекларацией — `DONE` локально; production
    ceremony остаётся `PENDING`.
24. `CAP-006`: CapabilityCertificate получил live lifecycle: heartbeat renewal,
    idempotent replay, same-epoch equivocation rejection, обязательный
    `previous_hash` для следующего epoch и исключение expired infrastructure
    node из node/peer listing — `DONE` unit/integration и 8-process cluster.
25. `CAP-007`: существующий signed Advertisement gossip теперь переносит
    CapabilityCertificate high-watermark; каждая Discovery проверяет rollback/
    chain/equivocation, а peer candidate возвращается только после сходимости
    минимум двух sources на текущем head — `DONE` three-DB integration;
    production multi-operator rollout остаётся `PENDING`.
26. `PEER-006`: Home больше не держит подписанный peer-set бесконечно в памяти
    при outage D1/D2/D3; persisted и in-memory `valid_until` одинаково
    fail-closed, invalid/missing state очищает stale guards/reserves — `DONE`
    unit/runtime; production source provisioning остаётся `PENDING`.
27. `SIM-002`: детерминированный Relay availability baseline сравнивает single
    path, 3-path fallback и 6-of-10 при 30% независимых отказов; отдельный test
    фиксирует availability cost multi-hop — `DONE` локально. Shared failure
    domains, latency/queueing, malicious routing и traffic-correlation —
    `PENDING`.

## Исторические проверки до текущего pass — 2026-08-22

Backend test runner:

- root/shared/Discovery/simulator: `350 passed`;
- Home: `43 passed`;
- Storage: `10 passed`;
- Relay: `14 passed`;
- всего: `417 passed`, функциональных падений нет;
- остаются только FastAPI `on_event` deprecation warnings.

Локальный cluster test поднимает восемь реальных uvicorn-процессов только на
`127.0.0.1`: D1/D2/D3, Home A/B/C, Relay и Storage. Последний подтверждённый
результат: `49/49 PASS`.

Эти результаты не подтверждают изменения development pass от 2026-08-23.
Согласно указанию владельца после интеграции тесты не запускались.

## Следующая верификация — только после отдельного разрешения

1. Static/import gate на целевом Python runtime, затем unit/property tests.
2. Три независимые Discovery: quorum, split-view, stale/rollback и outage.
3. Home A/B/C: Route epochs, direct/WSS/HTTP fallback, ACK и restart.
4. Relay: duplicate/reorder/replay, quotas, backpressure, bad target и failure.
5. Storage A/B: fixed cell integrity, write quorum, replica loss, ACK и expiry.
6. coturn: credential expiry, UDP/TCP/TLS NAT allocation и relay-only IP leak.
7. Chaos: kill/restart/partition с фактическими логами и сохранностью state.

Evidence текущего запуска:
`project/test-results/local-node-cluster/20260822T141248Z-611880f0/summary.json`.
Каталог намеренно git-ignored: содержит runtime DB/logs и создаётся заново
командой `python3.11 scripts/local-node-cluster-test.py`.

Simulator v3 evidence:
`project/test-results/trust-simulator/20260822-v3.json`: при 30% независимых
Relay failures single-path delivery составил `70.35%`, 3-path/need-1 —
`97.05%`, 6-of-10 — `84.30%`. Это ограниченный availability baseline без
latency, shared failure domains и privacy claim.

Дополнительно проверены 5-of-7 CapabilityCertificate, quorum TrustRecord
promotion и реальная background pull-репликация D1→D2/D3, signed persistent WebSocket binary
batches, Home session reuse,
Relay/Storage/Discovery synthetic challenges, signed evidence persistence,
bounded Reliability aggregation, live OperationalKey rotation, link-sequence
replay close, sticky Safe Mode при equivocation и продолжение data plane во
freeze. Подписанный gossip `head` обнаруживает stale/eclipsed view по трём
независимым sources без rollback локальной authority chain. Отдельно проверен
ChallengeAssignment lifecycle: 5-of-7 persistence,
observer-only pull, portable Operational-Key authentication на D2 без bearer
secret D1, persistent proof-replay rejection, signed ACK, запрет completion до ACK и привязка завершения
к подходящему signed TrustObservation. Loopback также обнаружил и подтвердил
исправление несовместимого `proxy`-аргумента с закреплённым `websockets==14.1`.
Просроченный Operational Certificate фактически отклоняется Discovery с HTTP
`403` в enforce mode; старый, ещё действующий сертификат после rotation также
отклоняется без отката highest-seen operational key. После outage основной Discovery восстанавливает registry и
BootstrapRecord, а перезапущенный Relay с пустым trust cache снова разрешает
target через восстановленный control plane.
Root-signed Operational Credential state с monotonic epoch и previous hash
сходится D1→D2/D3; portable pull/ACK/observation на D2 фактически работает в
`OPERATIONAL_CREDENTIAL_STATE_MODE=enforce`. ACK/observation gossip проверяет
исторический сертификат на время подписанного события, поэтому rotation не
возвращает старому ключу live-доступ и не уничтожает ранее валидное evidence.
Quorum-signed serial revocation независимо сходится D1→D2/D3: D2 возвращает
`403` новому portable request со скомпрометированным ключом, а подписанные до
`effective_at` ACK и TrustObservation сохраняются на всех трёх Discovery.
Отзыв не меняет NodeID, Level или Capability; node-wide TrustRecord revocation
остаётся отдельным действием.
Node-wide revocation Home C также независимо сошлась D1→D2/D3, исключила ноду
из публичного каталога, сохранила `compromised` в authoritative projection и
вернула `403` на попытку повторной регистрации тем же Root/Operational key.
Удлинённый chaos run также выявил и исправил ложный offline flap: тестовый
threshold 30s был меньше реального heartbeat interval 60s; теперь 120s.
Три Discovery независимо приняли одну signed RouteDescriptor chain из трёх
epochs, вернули идентичные проверяемые записи и отклонили rollback epoch.
Relay фактически закрыл WSS connection с кодом `4408` при превышении
deployment batch quota.
Secure mesh bootstrap теперь fail closed без отдельного `MESH_NOTIFY_SECRET`;
полный runner реально включает `shared/mesh/tests`. Peer selector исключает
self/unvalidated/single-source candidates, сохраняет guards при rotation и
возвращает degraded set при недостаточной operator diversity.
Opaque mailbox live round-trip сохранил 4 KiB fixed cell по случайному token,
вернул ciphertext, расшифровал payload только на вызывающей endpoint-стороне и
удалил entry capability-bound ACK.
Unknown NodeID flood не создаёт per-identity limiter state; пустой Discovery
catalog negative-cache'ится и concurrent lookup выполняет один refresh.
Два независимо подписавших Discovery observation формируют selector-ready
Relay candidate; один source кандидата не создаёт, а разные валидные
NodeAdvertisement hashes одного subject/epoch исключают subject fail closed.
Три независимые Discovery DB приняли один и тот же observation с полной
проверкой source Discovery capability и сохранили идентичное evidence.
Home signed peer runtime локально проверяет source-set против authority epoch,
создаёт отдельный 32-byte CSPRNG seed, атомарно сохраняет guards и использует
reserves только после отказа всех active peers. Enforce mode не откатывается к
legacy неподписанному каталогу.
Legacy heartbeat worker больше не меняет trust level при активном Trust Ledger:
offline формирует только reliability candidate; recovery удаляет candidate, а
state mutation остаётся за quorum-signed degradation TrustRecord.
Восемь реальных процессов повторно прошли весь baseline с Home/Relay/Storage в
`FEDERATION_NODE_ID_MODE=enforce`; их health NodeID фактически совпали с
root-derived `identity_node_id` Discovery, включая доставку после OperationalKey
rotation при неизменном NodeID.

Системный Python 3.9.6 не поддерживается и runner отклоняет его до collection.
Для воспроизводимого запуска добавлены `.python-version` и
`scripts/test-backend.sh`; существующий старый `.venv` намеренно не удалялся.

## Правило готовности

Компонент не получает `ready` без положительных/негативных тестов, логов и
метрик, restart/replay/expiry/revocation проверки, residual-risk записи и
прохождения соответствующего security gate.
