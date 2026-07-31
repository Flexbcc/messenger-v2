# Architecture Decision Records (ADR)

## Назначение
Здесь фиксируются значимые архитектурные решения: контекст, рассмотренные
варианты, выбор и последствия. ADR не редактируются задним числом — если
решение меняется, создаётся новый ADR, который помечает старый как
`Superseded`.

## Формат имени файла
```
NNNN-краткое-название.md
```
Например: `0001-choice-of-transport-protocol.md`

## Шаблон

```markdown
# NNNN. Название решения

## Статус
Proposed | Accepted | Rejected | Superseded by ADR-XXXX | Deprecated

## Дата
YYYY-MM-DD

## Контекст
Какая проблема требует решения и какие есть ограничения.

## Рассмотренные варианты
1. Вариант A — плюсы/минусы
2. Вариант B — плюсы/минусы

## Решение
Что выбрано и почему.

## Последствия
Что это решение меняет, какие компромиссы принимаются, на что это влияет
в других разделах спецификации.
```

## Список ADR
| № | Название | Статус |
|---|---|---|
| [0001](0001-protocol-first-architecture.md) | Протокол как основа архитектуры, а не фреймворк | Accepted |
| [0002](0002-e2ee-scheme-x3dh-double-ratchet.md) | Схема E2EE: X3DH + Double Ratchet вместо собственной криптографии | Accepted |
| [0003](0003-core-language-rust.md) | Референсный Core на Rust с FFI-биндингами | Accepted |
| [0004](0004-mvp-staged-implementation.md) | Поэтапная реализация MVP: язык на сервис, временный Crypto Provider за стабильным Crypto API | Accepted |
| [0005](0005-reuse-legacy-projects-and-real-crypto.md) | Основа реализации: перенос лучшего из старых проектов; настоящий E2EE (libsignal_protocol_dart) вместо временного | Accepted |
| [0006](0006-staged-decentralization-bootstrap-authority.md) | Поэтапная децентрализация: bootstrap-центр регистрации и мониторинга нод | Accepted |
| [0007](0007-password-identifier-login-bridge.md) | Временный мост: вход по идентификатору (телефон/логин/email) + пароль | Accepted |
| [0008](0008-calls-signaling-and-media-relay.md) | Звонки: сигналинг поверх E2EE-канала сообщений, медиарелей — новый Turn Node | Accepted |
| [0009](0009-node-enrollment.md) | Node Enrollment: Discovery как Control Plane (trust lifecycle, node_token) | Accepted |
| [0010](0010-node-attestation-and-gateway.md) | Attestation (build hash, signed release) + Gateway Node | Accepted |
| [0011](0011-service-to-service-security.md) | Service-to-service federation auth (signed internal API) | Accepted |
