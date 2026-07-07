# Turn Node

Роль по спецификации: [0605_TURN_NODE.md](../../spec/0605_TURN_NODE.md) —
ретрансляция медиапотоков звонков (SRTP), когда P2P невозможен.
Сигналинг звонков (offer/answer/ICE) сюда не относится — см.
[0303_CALLS.md](../../spec/0303_CALLS.md).

## Статус
Частично подключён:
- Саморегистрация и heartbeat в Discovery Node (`capabilities=["turn"]`) —
  как у остальных нод, см. `app/node_registration.py`.
- `POST /turn/credentials` — выдаёт временные TURN-учётные данные
  (username/password/ttl/uris) по стандартной схеме "TURN REST API"
  (shared secret, HMAC-SHA1), совместимой с параметрами coturn
  `use-auth-secret` + `static-auth-secret`.

**Не реализовано этим сервисом и не будет:** сама ретрансляция
UDP/RTP-медиапотока (RFC 8656). Это осознанное решение (см. ADR-0008,
0605_TURN_NODE.md → Назначение) — переиспользовать существующую
проверенную реализацию (референс: [coturn](https://github.com/coturn/coturn)),
а не писать TURN с нуля, тем же принципом, что и выбор libsignal для E2EE
(ADR-0002).

## Как поднять реальный TURN рядом с этим сервисом
1. Установить и запустить coturn (или другой TURN-сервер, поддерживающий
   `use-auth-secret`) на `TURN_SERVER_HOST:TURN_SERVER_PORT`.
2. Указать в его конфиге `static-auth-secret`, совпадающий с
   `TURN_SHARED_SECRET` этого сервиса.
3. Клиент получает credential через `POST /turn/credentials` и передаёт
   `username`/`password`/`uris` в конфигурацию `RTCPeerConnection`
   (`iceServers`) — этим уже занимается клиентский слой WebRTC, не этот
   сервис.

Без реального TURN-сервера рядом этот сервис по-прежнему полезен для
разработки/тестирования STUN-only сценариев и для проверки
discovery-регистрации, но не даёт настоящего медиарелея за NAT.

## Переменные окружения
| Переменная | По умолчанию | Назначение |
|---|---|---|
| `TURN_NODE_ID` | `turn-local` | Идентификатор ноды в Discovery |
| `TURN_NODE_PUBLIC_URL` | `http://localhost:8006` | URL этого FastAPI-сервиса (не TURN-порта) |
| `DISCOVERY_NODE_URL` | `http://localhost:8003` | Discovery Node для регистрации/heartbeat |
| `TURN_SERVER_HOST` / `TURN_SERVER_PORT` | `localhost` / `3478` | Адрес реального TURN-сервера, который отдаётся клиенту в `uris` |
| `TURN_SHARED_SECRET` | dev-значение | Должен совпадать с `static-auth-secret` TURN-сервера. **Обязательно сменить вне разработки.** |
| `TURN_CREDENTIAL_TTL_SECONDS` | `600` | Срок жизни выданных credential |
