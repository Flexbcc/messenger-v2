# DECISIONS

_Только окончательно принятые решения. Подробности — в spec/ADR/._

- **ADR-0001** — Protocol-first: сначала спецификация протокола, потом реализация.
- **ADR-0002** — E2EE-схема X3DH + Double Ratchet (не собственная крипто).
- **ADR-0003** — Rust как референсный язык Core (целевой, не для MVP).
- **ADR-0004** — MVP поэтапно: язык на сервис, Crypto API стабилен, реализация временна.
- **ADR-0005** — Основа из старых проектов (secret_room/secure-messenger); backend Python/FastAPI; клиент Flutter; настоящий E2EE через `libsignal_protocol_dart` сразу.
- **ADR-0006** — Bootstrap-стадия: один корневой Discovery Node для регистрации/мониторинга нод. Осознанное временное отступление от Decentralization First, с roadmap на децентрализацию.
- **ADR-0007** — Временный мост: регистрация телефон(обяз.)+имя+логин/email(опц.)+пароль; вход по любому идентификатору+пароль. Argon2id-хэш. Осознанное отступление от «без паролей» (0300_CRYPTO.md), roadmap — убрать после появления привязки устройств к Identity.
- **ADR-0008** (2026-07-06) — Звонки: сигналинг (offer/answer/ICE) — control-сообщения поверх уже существующего E2EE-канала 1:1 сессии (тот же паттерн, что sender-key в группах), backend-ноды не меняются. Медиарелей (SRTP при недоступном P2P) — новый тип узла Turn Node, self-registration в Discovery по паттерну ADR-0006. См. spec/0303_CALLS.md, spec/0605_TURN_NODE.md.
- **Turn Node: механизм выдачи credential** (2026-07-06, закрывает открытый вопрос из ADR-0008) — credential выдаёт сам turn-node через `POST /turn/credentials` (не Home Node), схема "TURN REST API" (shared secret + HMAC-SHA1, совместимо с coturn `use-auth-secret`). Без авторизации вызывающего для MVP (как у media-node) — смягчается TTL, не проверкой личности. См. `services/turn-node/README.md`.
- **Устойчивость звонка к сетевым сбоям** (2026-07-06, пользовательское требование) — ICE `disconnected` не завершает звонок (только UI «ожидание сети»), только `failed`/таймаут восстановления (20с) — реальный teardown. Реализовано в `AppController._onMediaConnectionState`/`_teardownAfterMediaFailure`, см. spec/0303_CALLS.md → «Устойчивость соединения».
- **WebRTC-пакет: `flutter_webrtc`** (2026-07-06) — единственный модуль, трогающий его напрямую — `lib/calls/call_media_controller.dart` (`CallMediaController`), по аналогии с изоляцией libsignal в `CryptoService`. `AppController` только оркестрирует (сигналинг, состояние звонка), не трогает WebRTC API сам.

## Технологии (подтверждены)
- Backend: Python + FastAPI + SQLite (MVP).
- Client: Flutter + Riverpod + libsignal_protocol_dart.
- UI: чёрно-белый минимализм, Apple HIG (design.md).

- **БД**: остаёмся на SQLite (2026-07-05) — не переходим на PostgreSQL, пока нет реальной многопользовательской нагрузки.

- **Групповое E2EE** (2026-07-05): sender-key схема реализована через libsignal_protocol_dart group-примитивы (не своя крипто). Распространение ключа — control-сообщениями поверх существующих 1:1 pairwise-сессий.

## Открыто (НЕ решено)
- Private Mode: реальное шифрование скрытых чатов (хэш PIN уже сделан — см. CURRENT_STATE) требует отдельного security review перед реализацией.
