# OUO v1 — каталог threat tests для инфраструктуры нод

Статусы: `PASS` — автоматизировано и прошло локально; `PARTIAL` — проверена
только часть свойства; `PENDING` — нужен следующий слой или внешний стенд.

| ID | Угроза/свойство | Автоматическая проверка | Статус |
|---|---|---|---|
| NODE-ID-001 | Node A не выдаёт себя за Node B | root/operational cert signature tests | PASS |
| NODE-ID-002 | Смена operational key не меняет NodeID | credential rotation test | PASS |
| NODE-ID-003 | Legacy alias нельзя тихо привязать к другому Root | Discovery identity conflict test | PASS |
| NODE-ID-004 | Live OperationalKey rotation сохраняет NodeID и восстанавливает federation | eight-process chaos test | PASS |
| NODE-ID-005 | Просроченный Operational Certificate не регистрируется | live Discovery enforce test | PASS |
| NODE-ID-006 | Data plane подписывается self-certifying NodeID, а не mutable alias | unit + 8-process enforce cluster | PASS |
| NODE-ID-007 | Старый, ещё валидный Operational Certificate не откатывает key после rotation | highest-seen unit/integration + live cluster replay | PASS |
| NODE-ID-008 | D1/D2/D3 имеют один root-signed credential high-watermark; старый key не проходит live, но валидная история сохраняется | chain/gossip/live admission unit + 8-process enforce cluster | PASS |
| NODE-ID-009 | Два разных валидных root-signed credential state одного epoch замораживают control plane; unsigned конфликт freeze не вызывает | authenticated-conflict integration | PASS |
| NODE-ID-010 | Registration/heartbeat принимает только следующий credential state и не откатывает renewal key | transactional Discovery integration | PASS |
| NODE-ID-011 | 4-of-7 не могут отозвать Operational Certificate; 5-of-7 могут | revocation quorum unit/integration | PASS |
| NODE-ID-012 | Отозванный serial/key не проходит registration, heartbeat или portable live admission, но pre-revocation ACK/observation остаются валидными | event-time integration + eight-process cluster | PASS |
| NODE-ID-013 | Serial revocation сходится D1/D2/D3 и не меняет NodeID/Level/Capability; только валидный quorum conflict замораживает governance | three-DB authenticated-conflict gossip + cluster | PASS |
| NODE-ID-014 | Новый Root не наследует alias, Level или infrastructure Capability старого скомпрометированного NodeID | fail-closed Root boundary integration | PASS |
| NODE-ADV-001 | Endpoint нельзя изменить после подписи | NodeAdvertisement tamper test | PASS |
| NODE-ADV-002 | Старый advertisement epoch отклоняется | anti-rollback test | PASS |
| NODE-ADV-003 | Один Discovery observation не создаёт candidate; два certified sources создают | aggregation + three-DB tests | PASS |
| NODE-ADV-004 | Разные signed advertisements одного subject/epoch исключают subject | conflict/equivocation tests | PASS |
| NODE-ADV-005 | Secure heartbeat не может продлить присутствие без свежего signed Advertisement; expired record исключается из node/peer listing | enrollment + Discovery heartbeat/catalog integration | PASS |
| CONFIG-002 | Capability/Trust enforce нельзя активировать без Authority State; distributed Trust enforce требует два Authority/Trust gossip peer origin | secure-env preflight tests | PASS |
| CAP-001 | L0 не получает Relay/Storage самодекларацией | Discovery enforce integration | PASS |
| CAP-002 | 4-of-7 не создают CapabilityCertificate | quorum tests | PASS |
| CAP-003 | 5-of-7 создают валидный certificate | unit + eight-process cluster | PASS |
| CAP-004 | Revoked/expired validator не голосует | capability tests | PASS |
| CAP-005 | Secure profile не принимает self-declared infrastructure role без quorum CapabilityCertificate; federation authorization использует certified capabilities | secure-env/Compose contract + Discovery/TrustCache integration | PASS |
| CAP-006 | CapabilityCertificate нельзя тихо заменить в том же epoch или вне hash-chain; missing/expired certificate прекращает infrastructure heartbeat/listing | certificate lifecycle unit/integration + live cluster rotation | PASS |
| CAP-007 | D1/D2/D3 не используют старый CapabilityCertificate после принятия нового distributed head; candidate ждёт минимум два согласованных source | three-DB gossip convergence/rollback/equivocation tests | PASS |
| TRUST-001 | Candidate не выбирает committee | deterministic external selection tests | PASS |
| TRUST-002 | Self telemetry не является evidence | external observation tests | PASS |
| TRUST-003 | 4-of-7 не повышают ноду | Discovery TrustRecord integration | PASS |
| TRUST-004 | 5-of-7 применяют promotion | Discovery endpoint + cluster test | PASS |
| TRUST-005 | Conflicting epoch сохраняет equivocation evidence | TrustLedger store tests | PASS |
| TRUST-006 | Локальный heartbeat outage не меняет authoritative level без quorum | observe candidate integration | PASS |
| TRUST-007 | D1/D2/D3 повторно проверяют и независимо хранят quorum TrustRecord | three-ledger gossip convergence + pull tests | PASS |
| TRUST-008 | Quorum TrustRecord для ещё неизвестной ноды применяется после её регистрации; conflicting replica включает freeze | late-reconciliation + equivocation integration | PASS |
| TRUST-009 | Node-wide suspension/revocation блокирует registration, heartbeat, portable live work и NodeAdvertisement; pre-decision historical event остаётся проверяемым | shared admission integration + live cluster | PASS |
| TRUST-010 | Revocation terminal; suspension не обходится promotion и снимается только следующим quorum reinstatement | TrustLedger state-machine tests | PASS |
| TRUST-011 | Admin approve/reinstate/re-enroll/grandfather и manual promote/demote не обходят quorum deny/enforce | admin admission integration | PASS |
| TRUST-012 | Suspension→reinstatement применяется D1/D2/D3 в следующих Authority epochs; событие в suspension window остаётся запрещённым | service/timeline integration + live cluster | PASS |
| CHALLENGE-001 | Relay/Storage/Discovery проверяются внешним observer без user/route fields в evidence | unit + eight-process cluster | PASS |
| CHALLENGE-002 | Self-observation, signature tamper и commitment replay отклоняются | Discovery integration | PASS |
| REPUTATION-001 | Один observer имеет не более одного веса на type/epoch; suspended observer исключён | integration + cluster | PASS |
| OBSERVER-001 | Subject исключён; selection детерминирован и предпочитает authority-supplied diversity groups | selection tests | PASS |
| ASSIGN-001 | 4-of-7 не выдаёт ChallengeAssignment; observer set нельзя заменить | quorum assignment tests | PASS |
| ASSIGN-002 | Assignment видит назначенный authenticated observer; ACK подписан его Operational Key | Discovery lifecycle integration | PASS |
| ASSIGN-003 | Self-reported completion невозможен: нужен accepted ACK и matching signed TrustObservation | Discovery lifecycle integration | PASS |
| ASSIGN-004 | Один subject/type/epoch не принимает два разных quorum assignment | persistence conflict + Safe Mode | PASS |
| ASSIGN-005 | Quorum assignment переживает отказ исходной Discovery и независимо появляется в D2/D3 | three-DB + background pull cluster tests | PASS |
| ASSIGN-006 | Observer получает/ACK назначение через D2 без переносимого bearer secret D1 | Operational proof, replay, portable ACK unit + cluster tests | PASS |
| ASSIGN-007 | Signed ACK переживает отказ принимающей Discovery и независимо проверяется D1/D3 | append-only ACK gossip integration + cluster tests | PASS |
| ASSIGN-008 | Completion требует matching signed observation и сходится после отказа D2 | portable evidence + append-only observation gossip + cluster tests | PASS |
| RANDOM-001 | 4-of-7 не создают RandomnessCheckpoint; tamper seed/snapshot/chain отклоняется | primitive tests | PASS |
| RANDOM-002 | Даже quorum-signed assignment с неправильным observer set отклоняется | scheduler + Discovery enforce integration | PASS |
| RANDOM-003 | D1/D2/D3 сходятся к checkpoint до принятия assignment; conflict включает freeze | gossip integration + 8-process cluster | PASS |
| SAFE-001 | Quorum equivocation замораживает control, не data plane | eight-process cluster | PASS |
| SAFE-002 | Freeze переживает restart и снимается только recovery quorum | state-machine tests | PASS |
| SAFE-003 | Три подписанных Discovery head с большим epoch gap замораживают governance без rollback/data-plane stop | gossip integration | PASS |
| AUTH-001 | 4-of-7 не меняют authority; новый committee не назначает сам себя | AuthorityCheckpoint quorum tests | PASS |
| AUTH-002 | Authority epoch идёт без gap и связан previous hash | chain/rollback tests | PASS |
| AUTH-003 | Conflicting quorum checkpoint одного epoch включает Safe Mode | Discovery integration | PASS |
| AUTH-004 | D1/D2/D3 сходятся к одной checkpoint chain через independently authenticated sources | three-DB gossip convergence + pull test | PASS |
| AUTH-005 | HTTP/source spoofing не подменяет checkpoint view | Operational signature + certified Discovery capability tests | PASS |
| RECOVERY-001 | 2-of-5 offline keys не снимают Safe Mode; 3-of-5 снимают | recovery primitive + Discovery integration | PASS |
| RECOVERY-002 | Compromised normal authority не подписывает emergency recovery | key-role separation tests | PASS |
| RECOVERY-003 | Replacement authority становится effective, следующий normal checkpoint подписывает новый quorum | recovery-to-normal chain integration | PASS |
| RECOVERY-004 | Одинаковая ceremony применяется на физических D1/D2/D3 | external recovery drill | PENDING |
| DISC-001 | Discovery не может изменить user-signed bootstrap | signature tamper test | PASS |
| DISC-002 | D1/D2/D3 независимо хранят один record | eight-process cluster | PASS |
| DISC-003 | Остановка D1 не убирает record из D2/D3 | eight-process cluster | PASS |
| DISC-004 | Все Discovery offline, established route продолжает работать | Home cached data-plane path | PARTIAL |
| DISC-005 | После возврата Discovery cold Relay снова разрешает target через persisted registry | eight-process outage/rejoin cluster | PASS |
| ROUTE-001 | Старый route epoch отклоняется | RouteDescriptor tests | PASS |
| ROUTE-002 | Current→next связан hash/commitment | transition tests | PASS |
| ROUTE-003 | Подмена ingress ломает подпись | route tamper test | PASS |
| ROUTE-004 | D1/D2/D3 хранят точную endpoint-signed current/next/next+1 chain | eight-process cluster | PASS |
| ROUTE-005 | Persistent cache отклоняет rollback, gap и same-epoch equivocation | Discovery integration + cluster | PASS |
| FED-001 | Exact replay отклоняется | persistent nonce + live HTTP replay | PASS |
| FED-002 | Поля envelope и conversation metadata cryptographically bound | tamper tests | PASS |
| FED-003 | Relay не меняет origin identity | forwarded-by separation test | PASS |
| FED-004 | Trust cache разрешает non-conflicting root-derived NodeID и fail-closes duplicate binding | dual-index tests | PASS |
| RELAY-001 | DROP/Relay outage не ломает direct path | cluster Relay stop | PASS |
| RELAY-002 | Relay не форвардит произвольный URL | URL/catalog enforcement tests | PASS |
| RELAY-003 | Control plane uncertain → Relay fail closed | D1 outage cluster test | PASS |
| RELAY-004 | Peer не обходит connection/batch resource budgets | budget unit test + live WSS quota close | PASS |
| PEER-001 | Single-source/unvalidated/self candidate не попадает в active set | peer-selection tests | PASS |
| PEER-002 | Guards переживают partial rotation; active/reserve не пересекаются | deterministic selection tests | PASS |
| PEER-003 | Недостаточная diversity даёт degraded set, а не заполнение одним operator | diversity-cap tests | PASS |
| PEER-004 | Home enforce mode не откатывается к unsigned single-Discovery catalog | runtime fallback tests | PASS |
| PEER-005 | Reserves используются только после отказа всех active peers | runtime ordering test | PASS |
| PEER-006 | Подписанный in-memory peer-set не переживает свой `valid_until`; invalid/missing persisted state очищает stale peers | Home runtime expiry tests | PASS |
| MESH-001 | Signed-mode mesh push не стартует без independent notify secret | secure-env + mesh router tests | PASS |
| LINK-001 | Persistent binary WebSocket переносит несколько batches | cluster test | PASS |
| LINK-002 | Повтор/reorder batch sequence отклоняется после restart | store + live close 4403 | PASS |
| LINK-003 | Home переиспользует persistent Relay session и reconnect один раз | unit + live cluster | PASS |
| CELL-001 | Real/dummy имеют одинаковый fixed size | XChaCha20 cell tests | PASS |
| CELL-002 | Corrupt/tagged cell не проходит AEAD | tamper test | PASS |
| STORAGE-001 | Duplicate packet не дублируется | unit + cluster idempotency | PASS |
| STORAGE-002 | Cell сохраняется после restart | unit + process restart | PASS |
| STORAGE-003 | ACK удаляет ровно принятую cell | unit + cluster | PASS |
| STORAGE-004 | Corrupt/old encrypted cell обнаруживается endpoint AEAD | требует endpoint E2EE test | PENDING |
| STORAGE-005 | Новая mailbox table не содержит UserID/DeviceID и принимает только fixed-size ciphertext | schema/unit + live cluster | PASS |
| STORAGE-006 | ACK с чужой mailbox capability не удаляет cell | Storage capability test | PASS |
| STORAGE-007 | Mailbox fetch имеет hard page limit и `has_more` | Storage bounded-response test | PASS |
| HOME-001 | Message DB сохраняется после restart | process restart cluster test | PASS |
| HOME-002 | Home не получает plaintext/E2EE keys | negative integration/audit | PENDING |
| AVAIL-001 | D1 outage, Relay outage, Home restart | cluster failure matrix | PASS |
| AVAIL-002 | Network partition/rejoin и certificate expiry | timed chaos harness | PENDING |
| AVAIL-003 | Multipath и 6-of-10 повышают delivery при независимых Relay failures; multi-hop имеет измеримую availability cost | deterministic Relay failure simulator, 2,000 trials | PASS |
| SYBIL-001 | 10,000 unsigned L0 не получают Relay capability | production verifier simulator | PASS |
| COLLUSION-001 | Захват 5-of-7 committee измеряется при 1/5/10/20/34 из 100 compromised validators | 2,000 deterministic trials/config | PASS |
| ECLIPSE-001 | Single-source 10k Sybil исключаются; одна operator group ограничена 2/6 active slots | production-selector simulator | PASS |
| ECLIPSE-002 | Spoofed diversity при уже скомпрометированном capability layer остаётся измеримым residual risk | simulator (57% active eclipse в конкретных 100 trials) | PARTIAL |
| DDoS-001 | Cheap invalid input не вызывает body read/trust lookup/crypto | 1k malformed admission test | PASS |
| DDoS-002 | Unknown NodeID flood не раздувает per-node limiter и пустой catalog не создаёт GET amplification | bounded-state + single-flight tests | PASS |
| DDoS-003 | Unknown/oversized chunked request отклоняется до crypto и nonce state | bounded-stream admission tests | PASS |
| MIX-001 | Correlation materially ниже Basic Relay | traffic simulator | PENDING |
| TURN-001 | relay-only скрывает peer IP через NAT | внешний network test | PENDING |

Каждый новый security mechanism должен добавлять ID, expected result и ссылку
на автоматический test. Реальные пользовательские идентификаторы, conversation
IDs и маршруты не должны попадать в evidence.
