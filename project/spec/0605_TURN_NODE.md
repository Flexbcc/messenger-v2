# 0605. Turn node

## Статус
Credential service и coturn contract реализованы; live NAT verification pending.

## Назначение
Узел ретрансляции медиапотоков звонков (SRTP), когда прямое P2P-соединение
между устройствами невозможно из-за NAT/firewall (Turn Node,
[[0004_GLOSSARY]]). Вводится вместе со схемой звонков — см.
[0303_CALLS.md](0303_CALLS.md).

Turn Node реализует протокол TURN (RFC 8656) поверх STUN — это не
собственный протокол проекта, а стандартный интернет-протокол; референсная
реализация — существующий сервер с открытым исходным кодом (например
coturn), а не написание TURN с нуля (тот же принцип, что уже применён к
E2EE в [ADR-0002](ADR/0002-e2ee-scheme-x3dh-double-ratchet.md) — не изобретать
то, для чего есть проверенное общепринятое решение).

## Ответственности
- Отдача STUN-ответов для обнаружения публичного адреса устройства (NAT
  traversal).
- Ретрансляция медиапотока (SRTP) между двумя устройствами звонка, когда
  ICE не смог установить прямой P2P-путь.
- Публикация собственной доступности как Capability в Discovery Node —
  тот же механизм self-registration + heartbeat, что уже применяется
  остальными нодами ([ADR-0006](ADR/0006-staged-decentralization-bootstrap-authority.md)).

Turn Node **не участвует** в сигналинге звонка (offer/answer/ICE-кандидаты
идут через существующий E2EE-канал сообщений, см. [0303_CALLS.md](0303_CALLS.md)) и
не имеет доступа к ключам DTLS-SRTP — согласуются они между устройствами
end-to-end. Turn Node видит непрозрачный зашифрованный медиапоток, объём
трафика и адреса сторон — не его содержимое (Privacy First, тот же уровень
метаданных, что уже описан для Relay Node в [0601_RELAY_NODE.md](0601_RELAY_NODE.md) →
Метаданные, видимые relay node).

## Отличие от Relay Node
Relay Node пересылает протокольные Packet (дискретные сообщения,
[0201_PACKETS.md](0201_PACKETS.md)) и не хранит состояние дольше одного
Packet. Turn Node удерживает состояние (allocation, RFC 8656) на весь
поток реального времени длительностью в звонок и работает с непрерывным
UDP/RTP-трафиком, а не с дискретными пакетами протокола. Смешение этих
двух ролей в одном компоненте нарушило бы Single Responsibility — поэтому
это отдельный тип узла, а не расширение Relay Node.

## Выбор Turn Node
Клиент получает список доступных Turn Node от Discovery Node тем же
способом, что и список Relay Node (Capability). Выбор конкретного Turn
Node на время звонка — по тем же критериям (география, задержка,
нагрузка), что и выбор Relay Node ([0601_RELAY_NODE.md](0601_RELAY_NODE.md) →
Выбор relay node).

## Ограничения (обязательны перед эксплуатацией вне тестового окружения)
- **Временные учётные данные TURN** (time-limited credentials, механизм
  REST API для TURN-серверов) — обязательны, чтобы Turn Node не превратился
  в открытый relay для произвольного стороннего UDP/TCP-трафика
  (классический риск неправильно настроенного TURN-сервера). **Решено**
  (2026-07-06): сам Turn Node выдаёт credential через `POST
  /turn/credentials` (shared secret + HMAC-SHA1, совместимо с coturn
  `use-auth-secret`) — не Home Node. Без авторизации вызывающего в MVP
  (тот же уровень доверия, что у Media Node сегодня) — абьюз смягчается
  коротким TTL credential, а не проверкой личности; см.
  `services/turn-node/README.md`. Пересмотреть, если Turn Node станет
  доступен за пределами доверенной сети.
- Rate limiting и ограничение полосы на allocation — по аналогии с
  ограничением частоты запросов у Relay Node ([0601_RELAY_NODE.md](0601_RELAY_NODE.md) →
  Ограничения), адаптированное к характеру трафика (непрерывный поток, а
  не дискретные запросы).

## Масштабирование
Как и Relay Node, Turn Node не хранит состояние дольше одного звонка —
любой участник может поднять собственный Turn Node, но публиковать его для
чужого трафика можно только после отдельной Turn Capability. Это не требует
координации состояния звонков между нодами.

## Реализованный service contract

FastAPI service не реализует TURN самостоятельно, а выдаёт time-limited REST
credentials для coturn с тем же `static-auth-secret`. Username содержит expiry
и случайный opaque suffix, но не UserID/DeviceID. Доступ требует device JWT,
имеет rate limit и TTL 60–3600 секунд.

Ответ перечисляет только включённые UDP/TCP/TLS URI, realm и обязательную для
privacy mode клиентскую политику `relay`. Secure startup fail closed при
development secrets. Health публикует только aggregate credential count и
эффективный contract, не идентификаторы звонящих.
