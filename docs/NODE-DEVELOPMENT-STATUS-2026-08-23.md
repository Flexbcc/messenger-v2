# Разработка нод — статус 2026-08-23

Этот срез относится только к локальному коду. Proxmox, контейнеры и внешние
сервисы не изменялись. Текущий проход выполнен без запуска тестов и процессов
по прямому указанию владельца; `git diff --check` не выявил whitespace errors.

## Реализованные участки

1. Node Identity, Operational Credential chain/rotation/revocation, отдельный
   X25519 Transport Key и краткоживущий root-signed Transport Certificate.
2. Capability/Level separation, quorum Trust Ledger, external observations,
   synthetic challenges, degradation/suspension/revocation и Safe Mode.
3. Signed BootstrapRecord, NodeAdvertisement и RouteDescriptor; multi-Discovery
   quorum, split-view detection, persistent anti-rollback и current/next/next+1.
4. Basic Relay: signed HTTP fallback, persistent WSS binary batches, replay
   stores, connection/frame/batch/time/resource quotas и trusted target check.
5. Storage v1: opaque mailbox tokens, encrypted fixed cells, TTL, ACK, disk
   budget, replication client и write quorum.
6. TURN: separated secret, opaque expiring credentials, relay-only contract и
   STUN reachability probe.
7. Privacy foundations: opaque ingress envelope, local route builder,
   independent-Discovery Transport Certificate gossip/quorum, multipath
   planner, Home-side multi-Discovery route planning, bounded Mix Pool, jitter
   и cover budget; Relay `/mix/ingress`, persistent per-hop replay и delayed
   next-hop dispatch, а также Home destination ingress с Storage write quorum
   подключены с fail-closed provider boundary.
8. Contact admission: endpoint-signed limited capability и bounded adaptive PoW.
9. Unified lifecycle для Home/Gateway/Relay/Storage/Media/TURN/Discovery roles и
   fail-closed secure Compose profile.
10. Async provider boundary, bounded persistent Unix-socket adapter и
    recipient-generated one-time SURB delivery contract без раскрытия Home
    отправителю.
11. Fail-closed replay capacity/backpressure semantics с учётом in-flight
    batches, exact sidecar response contract и adaptive cover scheduler со
    скользящим traffic budget.
12. Repeat-safe Home/Relay Mix lifecycle и multi-Discovery quorum resolution
    каждого следующего Relay hop без доверия одному registry.
13. Authenticated onion expiry без per-hop TTL extension и bounded single-flight
    Relay peer cache, ограниченный сроками всех подписанных credentials и
    исключающий Discovery lookup для каждой transport cell.
14. Authenticated per-hop capability binding: полный обычный route состоит из
    2–4 Relay layers и одной destination Home, остальные роли fail closed.
15. Storage padded mailbox fetch: фиксированное число same-size real/dummy
    slots, 1 MiB response budget и replica-safe merge; dummy определяется
    endpoint только после AEAD и не ACK-ается.
16. Secure Federation TrustCache принимает Operational signing key,
    capabilities и quotas только из совпавшего D1/D2/D3 peer-view и повторно
    проверяет root-signed Operational Certificate локально.
17. Basic Relay больше не доверяет одному Discovery при проверке target Home и
    выборе аварийного L2+ hub: требуется точный quorum peer-view, валидный
    Transport Certificate и соответствующая Home/Relay Capability; split view
    исключает ноду из маршрута.
18. ChallengeAssignment теперь образует проверяемую отдельную hash-chain для
    каждой пары subject/type: Discovery отклоняет разрыв `previous_hash` и
    вставку старого epoch после более нового назначения. Proposal builder также
    детерминированно выводит assignment ID из checkpoint и расписания, чтобы
    независимые валидаторы подписывали один объект, а не случайные UUID.
19. Home signed peer runtime теперь локально кворум-проверяет также
    Transport Certificate из Discovery observations и формирует подписанные
    наборы Storage/Media/TURN/Gateway. В enforce-режиме Storage/Media больше не
    откатываются на неподтверждённый статический URL.
20. Срок peer-view ограничен также минимальным expiry независимых Discovery
    observations; этот срок входит в consensus commitment и cache deadlines
    Home, Relay и Federation TrustCache.
21. Reliability Reputation теперь выдаёт hash-committed eligibility proposal
    для L0–L5 из внешних assignment-bound observations: минимальные observers,
    challenge types, sample size и success rate; protocol-invalid result
    блокирует eligibility. Общий endpoint возвращает кандидатов для quorum
    review, но никогда сам не меняет Level или Capability.
22. Discovery получил автоматический proposal-only scheduler synthetic
    challenges: по quorum RandomnessCheckpoint формируются repeat-safe unsigned
    availability/Relay/Storage/Discovery assignments, сохраняются отдельно и
    выдаются валидаторам. Discovery по-прежнему не подписывает их и не может
    единолично назначить observers.
23. Signed assignment принимается в enforce только при точном совпадении с
    детерминированным proposal. Просроченные unsigned proposals отмечаются как
    missed, а незавершённые observer jobs глобально закрываются как expired без
    создания фиктивного evidence и без автоматического наказания subject.
24. Security Reputation отделена от Reliability: повторно доставленное
    TrustRecord и Operational Credential Revocation equivocation evidence
    дедуплицируется, ответственность несут
    только валидаторы из пересечения подписантов конфликтующих ветвей. API
    выдаёт hash-committed suspension proposal, но санкцию применяет только
    отдельный quorum TrustRecord.
25. Reliability/degradation/security evidence интегрированы с Trust Ledger
    через детерминированные unsigned TrustRecord proposals. Приоритет конфликтов
    suspension > degradation > promotion; proposal привязан к ledger head,
    authority epoch, committee и evidence commitment и не применяется без
    validator quorum.
26. Реальный availability challenge lifecycle подключён ко всем secure node
    services: portable pull, signed ACK, quorum endpoint resolution, HTTPS
    health с проверкой self-certifying NodeID и portable signed observation.
    Нереализованные role challenges честно decline, а не подменяются health.
27. Реальные Storage и Discovery challenge adapters подключены: Storage
    выполняет authenticated bounded 4 KiB STORE→single-use GET→hash/byte verify
    в отдельной TTL-таблице; Discovery lookup сравнивает известную запись с
    независимым quorum TrustCache observer. Пользовательские mailbox/route
   данные не используются.
28. Relay delivery challenge выполняет реальный путь Observer A → проверяемый
   Relay → независимая Node B. Получатель подписывает domain-separated receipt
   своим Operational Key, поэтому Relay не может самостоятельно сфабриковать
   успех без ключа B.
29. TrustRecord proposal получил отдельный сбор validator votes, точную
   committee/credential/signature проверку и автоматическое применение только
   после threshold. Opt-in Validator runtime сверяет proposal и evidence через
   несколько Discovery и автоматически голосует за promotion/degradation.
   Security suspension остаётся fail closed до локальной проверки полных
   конфликтующих объектов по historical authority epoch.
30. Подготовлен переносимый PVE2 package на 12 логических нод: D1/D2/D3,
   Home A/B/C, Relay A/B, Storage A/B, Gateway и TURN API + coturn. У каждой
   ноды отдельный volume/identity boundary, заданы CPU/RAM/pids limits,
   loopback-only host exposure и staged authority/validator provisioning.

## Намеренно не подменено заглушкой

- Sphinx-like packet construction: async persistent sidecar-интерфейс есть, без
  рассмотренного provider runtime fail closed.
- K-of-N erasure coding: async sidecar-интерфейс и multipath planner есть, без
  рассмотренного codec encode/reconstruct fail closed.
- QUIC adapter отсутствует; верхний протокол transport-agnostic, baseline WSS.

Эти пункты нельзя честно назвать готовыми реализациями посредством собственной
неаудированной криптографии или выдачи обычного N/N fragmentation за K-of-N.

## Не подключено в общий data plane

- reviewed Sphinx provider и его process-start wiring;
- endpoint-side Sphinx build/reconstruction;
- K-of-N codec;
- adaptive cover controller реализован как bounded primitive; его data-plane
  wiring не включён до reviewed provider. Storage padded fetch реализован,
  endpoint periodic polling scheduler ещё не подключён;
- Contact Capability enforcement в Home API;
- production TLS/QUIC и реальная D1/D2/D3 operator diversity.
- автоматическое подписание security suspension до полной historical-authority
  проверки equivocation evidence;
- контейнерный package ещё не запускался и не подтверждён runtime-логами.

## Методы последующей проверки (не запускались)

1. Unit/property: exact schemas, signatures, expiry, rollback, replay, 4/7 vs
   5/7 quorum, revoked credentials, K-of-N reconstruction.
2. Integration: D1/D2/D3 registration/heartbeat, Home A→Relay→Home B, ACK,
   offline mailbox, multi-device, restart persistence и certificate rotation.
3. Malicious component: DROP/DELAY/REORDER/DUPLICATE/CORRUPT/REPLAY, stale and
   split-view Discovery, Storage delete/old/corrupt responses.
4. Chaos: kill/restart Home, Relay and Discovery, network partition/rejoin,
   address changes and bounded queues under slow peers.
5. TURN: cross-NAT UDP/TCP/TLS allocation and relay-only verification that peer
   addresses are not exposed to clients.
6. Quantitative Mix evaluation: delivery probability, P50/P95/P99, bandwidth,
   CPU/RAM, anonymity set and attacker sender-recipient correlation against the
   Basic Relay baseline.
7. Parser fuzzing and admission load: malformed WSS batches/cells/certificates,
   connection/HELLO/invalid-signature floods and bounded memory/CPU behavior.

## Граница готовности

Локальный security/control/basic-data foundation и конфигурация тестовой VM
реализованы, но новый кластер и Mix
Network не являются подтверждённо готовыми: это потребует выбора reviewed
Sphinx/K-of-N providers, интеграции оставшихся runtime paths и фактических
тестов с логами. До этого security claims ограничиваются свойствами кода, а не
результатами работающего стенда.
