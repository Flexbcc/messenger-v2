# OUO / messenger-v2 — Security Architecture & Threat Model v1

## Статус документа

Это целевая нормативная архитектура OUO v1. Документ не утверждает, что
описанные механизмы уже реализованы. Фактическое состояние и порядок внедрения
зафиксированы отдельно в
[`OUO-SECURITY-IMPLEMENTATION-ROADMAP-v1.md`](OUO-SECURITY-IMPLEMENTATION-ROADMAP-v1.md).

Источник требований — согласованный план пунктов 0–314. Эта редакция группирует
их по security boundaries и этапам, не меняя ключевые требования.

## Цель

Компрометация отдельного Home, Relay, Discovery, Storage, Main, L5 или части
инфраструктуры не должна автоматически раскрывать пользовательскую переписку,
ключи других компонентов или позволять захватить всю сеть.

Абсолютная безопасность невозможна: полностью скомпрометированное конечное
устройство видит plaintext до шифрования и после расшифровки. Главный принцип:

```text
ONE COMPONENT COMPROMISED != SYSTEM COMPROMISED
```

## Scope OUO v1

Входят:

- текстовые сообщения 1:1, затем групповые;
- E2EE и multi-device;
- пользовательские Home Nodes;
- Basic Relay, затем Mix Transport;
- небольшой Storage/offline mailbox для текста;
- распределённый Discovery;
- Node Identity, Trust, Reputation и Capability;
- голос после стабилизации текстового транспорта.

Не входят фотографии, видеоролики, документы, большие файлы, S3 media,
thumbnails, CDN и облачная история медиа. Существующий Media Node не удаляется,
но не входит в критический путь OUO v1.

## Security invariants

1. E2EE private keys никогда не передаются Home, Relay, Discovery, Storage,
   Main или L5.
2. Криптографическими endpoints являются пользовательские устройства.
3. Home, Relay, Discovery и Storage считаются потенциально недоверенными.
4. Нода не повышает свой уровень на основании собственной telemetry.
5. Identity, Reputation, Level и Capability — разные сущности.
6. Количество сообщений само по себе не доказывает доверие.
7. Identity, Level, Capability, Authority, Route и Update objects подписаны,
   versioned, имеют expiry и revocation.
8. Main, одна L5, один Discovery или один Release Key не контролируют зрелую
   сеть единолично.
9. При конфликте control plane применяется FREEZE; cached data plane продолжает
   работу по возможности.
10. Invalid signature/quorum/certificate, unknown critical version или AEAD
    failure приводят к REJECT (fail closed).

## Trust boundaries

| Boundary | Содержимое | Граница |
|---|---|---|
| Endpoint | User Device, plaintext | Полный root-компромисс устройства вне абсолютных гарантий |
| Cryptographic Identity | Identity Root, Device, Node Root, Validator keys | Ключи разделяются |
| Governance | L5 quorum, Emergency Root | Захват quorum компрометирует governance, но не E2EE plaintext |
| Availability | сеть, ISP, питание, uplink | Криптография не спасает физически исчерпанный канал |

## User Identity и устройства

- `UserID = HASH(IdentityRootPublicKey)` — self-certifying identity.
- Identity Root не является message encryption key.
- Каждое устройство имеет отдельный DeviceKey и Device Certificate.
- Device add/revoke подтверждаются Identity policy и вызывают rekey.
- Компрометация Phone Key не раскрывает другие Device/Recovery/Node/L5 keys.
- Recovery выполняется через заранее заданную `RecoveryPolicy`, не server reset.
- Recovery создаёт versioned и signed `IdentityTransition`.
- Для human-readable usernames нужен Key Transparency.
- QR/invite первого контакта содержит UserID, fingerprint и bootstrap data.

## E2EE и endpoint security

- Не создавать собственную message crypto.
- Для 1:1 использовать проверенный ratchet с forward secrecy и
  post-compromise security.
- Для групп рассматривать стандартизированную схему, например MLS.
- Multi-device означает независимые sessions/envelopes каждого Device.
- Device private keys по возможности hardware-backed и non-exportable.
- Локальная БД с plaintext шифруется отдельным ключом.
- Push передаёт только wake-up signal, а защищённые уведомления не содержат
  sender/message content.
- Secret Mode ограничивает screenshots, clipboard, autofill и preview там,
  где это допускает ОС.
- Production logs/crash dumps не содержат plaintext, keys и tokens.
- Disappearing messages — privacy feature, не DRM-гарантия.

## Node Identity

Каждая нода имеет постоянный Node Root Key:

```text
NodeID = HASH(NodeRootPublicKey)

Node Root
├── Operational Key
├── Transport/Relay Key
└── Validator Key
```

Node Root используется редко. Короткоживущий Operational Certificate включает
`node_id`, operational public key, validity и protocol version. Кража
Operational Key не означает вечную кражу Node Identity.

## Level, Capability и Trust

Уровни: L0 New, L1 Verified, L2 Relay, L3 Trusted Relay, L4 Infrastructure,
L5 Network Authority.

L0 обслуживает только собственных клиентов/трафик и не является
Relay/Discovery/Storage/Validator для других. Infrastructure rights выдаёт
versioned `CapabilityCertificate` с quota, expiry и quorum certificate. Level
не выдаёт автоматически все capabilities.

Reputation делится на Reliability (uptime/loss/latency/availability) и Security
(invalid signatures, replay, equivocation, forged state). Основой являются
external observations и synthetic challenges, а не self-telemetry.

Promotion использует независимо выбранный validator committee и quorum.
Кандидат не выбирает валидаторов. Решения записываются в hash-linked,
quorum-signed Trust Ledger; конфликтующие подписи дают evidence equivocation.

## Main и governance

Main — Genesis Root только на bootstrap. После формирования authority set её
operational authority отключается. Возможная остаточная роль — offline threshold
Emergency Root, например 3-of-5, только для catastrophic recovery. Захват
authority quorum компрометирует governance, но не должен раскрывать E2EE keys.

## Discovery, bootstrap и routes

Целевая конфигурация — минимум три независимых Discovery: D1/D2/D3. Discovery —
cache/directory/rendezvous, но не Identity, Route или message authority.

Пользователь подписывает `BootstrapRecord`; нода подписывает
`NodeAdvertisement`. Discovery только распространяет их.

После первого контакта пользователи передают внутри E2EE versioned
`RouteDescriptor` с current/next/next+1 epochs. Home не равен Ingress; контакт не
обязан знать реальный Home. Discovery используется для bootstrap/recovery, а не
для каждого сообщения.

Нода имеет ограниченный active peer set (ориентир 5–15): stable guards,
rotating peers и reserve peers. Candidates поступают из нескольких Discovery,
gossip и предыдущих trusted peers. Учитывается operator/subnet/ASN diversity.
Противоречивые views включают Eclipse Safe Mode/control freeze.

## Basic Relay и offline mailbox

До Mix реализуется простой надёжный Relay `A -> Relay -> B`, уже encrypted,
authenticated, replay-protected, quota- и capability-controlled.

Storage v1 хранит только random mailbox token, encrypted fixed-size cell,
expiry и opaque capability. Не хранит открытые UserID, conversation ID, sender
или полный route. Availability повышается replication/erasure coding. Secure
deletion означает уничтожение ключа; физическое удаление чужого ciphertext
доказать нельзя.

## Mix Transport

```text
OUO Protocol -> Mix Transport -> Transport Adapter -> WSS
                                                   -> QUIC (позже)
```

Protocol correctness не зависит от QUIC. Data plane использует persistent
connections и binary batches; REST остаётся control plane.

Mix privacy строится совместно из fixed-size cells, padding, batching,
multi-hop, reviewed Sphinx-like construction, per-hop IDs, replay/tagging
protection, multipath, K-of-N, Mix Pool, jitter, cover traffic, padded mailbox
polling и route rotation.

Relay знает только previous/next hop и локальные параметры, но не plaintext,
UserID, conversation ID, полный route или реальный Home. Cover ограничивается
budget и сокращается первым при перегрузке.

## DDoS и spam

Admission идёт от дешёвого к дорогому:

```text
network/connection limit -> address validation -> cheap token -> capability
-> rate limit -> bounded parsing -> expensive crypto
```

Adaptive PoW выключен в норме и применяется к anonymous bootstrap/unknown
connections/contact flood/mass registration при атаке. Первичный контакт
ограничивает `ContactCapability`: mailbox, expiry, quota и permissions.

## Voice

Voice имеет отдельный low-latency profile. Signaling проходит через E2EE OUO
control channel, media шифруется end-to-end. Baseline — P2P, затем TURN/Relay и
relay-only privacy mode. Relay видит timing/duration/bitrate metadata, но не
plaintext audio.

## Updates и supply chain

- Один Release Key недостаточен.
- Используются threshold signing и TUF-like ROOT/TARGETS/SNAPSHOT/TIMESTAMP.
- Root keys offline/hardware-backed и отсутствуют в CI.
- Проверяются artifact hash, version, expiry и rollback.
- Желательны reproducible builds и append-only release transparency.
- Rollout staged: canary -> small -> larger -> full.
- Discovery не является update authority.

## Cryptographic engineering

- Не создавать собственные encryption/signature/hash/KDF/RNG/key exchange/AEAD.
- Использовать CSPRNG ОС и проверенные библиотеки.
- Применять domain separation: `OUO/E2EE`, `OUO/TRANSPORT`, `OUO/ROUTE`,
  `OUO/STORAGE`, `OUO/ATTESTATION`, `OUO/DEVICE`.
- Secret values сравнивать constant-time средствами библиотеки.
- Objects содержат protocol/object version и algorithm identifiers.
- Optional и critical extensions различаются; unknown critical отклоняется.

## Logging, backups и telemetry

Не логировать plaintext, keys, social graph, conversation ID, full route,
mailbox token и E2EE message ID без строгой необходимости. Telemetry описывает
работу ноды, не коммуникацию пользователей. Backups шифруются у источника
отдельным ключом. E2EE keys не попадают в server backups. Production full memory
dumps запрещены по умолчанию.

## Verification и security gates

Каждая угроза становится контрактом:

```text
Threat ID -> attack scenario -> expected protection -> automated test -> residual risk
```

Обязательны unit/integration/property/fuzz/chaos, rotation, replay, downgrade,
partition и malicious-node tests. Simulator моделирует 100/1 000/10 000 нод,
Sybil, collusion, eclipse, relay failure и global observer. Для Mix измеряются
delivery, P50/P95/P99, bandwidth, CPU, RAM, anonymity set и correlation против
Basic Relay baseline.

| Gate | Объём |
|---|---|
| A | User Identity + Recovery + 1:1 E2EE |
| B | Node Identity + Capability + Trust |
| C | Distributed Discovery + Route Protocol |
| D | Basic Relay + Offline Mailbox |
| E | Mix Transport |
| F | Voice |
| G | Public hostile network |

## Security claims и абсолютные пределы

До внешнего аудита запрещены заявления «невозможно взломать» и «полностью
анонимный». OUO не гарантирует защиту plaintext на захваченном endpoint,
recovery без фактора, availability при физическом DDoS, governance после захвата
quorum, физическое удаление чужого ciphertext, исчезновение сообщения на
malicious client или одновременно нулевые latency/overhead и абсолютную
metadata anonymity.
