# Спецификация проекта

Этот каталог содержит полную спецификацию проекта: от видения и принципов до
протокола, компонентов инфраструктуры и API.

## Структура

| Диапазон | Раздел | Описание |
|---|---|---|
| `0000–0099` | Обзор | Цели, видение, принципы, глоссарий |
| `0100–0199` | Архитектура | Общая архитектура, компоненты, потоки данных, сеть |
| `0200–0299` | Протокол | Сообщения, доставка, Node Record (`0205`), Node Identity (`0206`), Capability/Trust (`0207`), Evidence (`0208`), Trust Ledger (`0209`), NodeAdvertisement (`0210`), BootstrapRecord (`0211`), RouteDescriptor (`0212`), Network Safe Mode (`0213`), Basic Transport batch (`0214`), Fixed Cell (`0215`), Synthetic Challenge (`0216`), Reliability Reputation (`0217`), Observer Selection (`0218`), ChallengeAssignment (`0219`), AuthorityCheckpoint (`0220`), Authority Gossip (`0221`), Emergency Authority Recovery (`0222`), Peer Selection (`0223`), Opaque Mailbox (`0224`), Federation Admission (`0225`), NodeAdvertisement Observation Gossip (`0226`), Home Signed Peer Runtime (`0227`), Quorum Degradation Boundary (`0228`), Federation NodeID Enforcement (`0229`), TrustRecord Gossip (`0230`), Federation Admission Body Bound (`0231`), Portable Observer Authentication (`0233`), ChallengeAssignment ACK Gossip (`0234`), TrustObservation Gossip (`0235`), RandomnessCheckpoint Scheduler (`0236`), Distributed Operational Credential High-Watermark (`0237`), Quorum Operational Credential Revocation (`0238`), Node Root Compromise Boundary (`0239`), Unified Node Runtime (`0240`), Opaque Ingress (`0241`), Transport Certificate (`0242`), Local Transport Route Builder (`0243`), Mix Pool и Cover (`0244`), Contact Admission (`0245`), Multipath/K-of-N boundary (`0246`), Mix Ingress Runtime (`0247`), Final Mailbox Dispatch (`0248`), SURB Delivery (`0249`), Transport Sidecar Protocol (`0250`), Padded Mailbox Polling (`0251`), Multi-Discovery Federation Trust (`0252`), Security Reputation (`0253`), TrustRecord Proposals (`0254`), Challenge Observer Runtime + signed Relay delivery receipt (`0255`), Independent Trust Validator Runtime (`0256`) |
| `0300–0399` | Криптография | Криптографическая схема, threat model, сетевая безопасность (`0305`) |
| `0400–0499` | Клиент | Клиентские приложения, multi-device (`0405`) |
| `0500–0599` | Ядро | Core-логика, общая для всех платформ |
| `0600–0699` | Узлы | Типы узлов инфраструктуры (home, relay, storage, media, discovery) |
| `0700–0799` | Хранилище | База данных, S3-совместимое хранилище |
| `0800–0899` | API | Публичные и внутренние API |
| `0900–0999` | DevOps | Развёртывание, CI/CD, эксплуатация |

## ADR

Архитектурные решения фиксируются отдельно в каталоге [`ADR/`](ADR/README.md)
по формату Architecture Decision Records.

## Как читать

Документы пронумерованы так, чтобы можно было проследить путь от идеи
(`0001_VISION.md`) до конкретной реализации (`0900_DEVOPS.md`). Начинайте с
[`0000_PROJECT.md`](0000_PROJECT.md).

## Статус

Черновик. Разделы заполняются по мере проработки проекта.
