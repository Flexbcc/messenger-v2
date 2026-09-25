# Relay Node

Роль по спецификации: [0601_RELAY_NODE.md](../../spec/0601_RELAY_NODE.md) —
пересылка Packet между Home Node без чтения содержимого.

## Статус
Подключён. Home Node сначала пробует прямую доставку; при ошибке —
резолвит живую relay-capable ноду через Discovery Node (см. ADR-0006) и
пересылает через неё (`POST /relay/forward` → `POST {target}/internal/deliver`).

Саморегистрация и heartbeat в Discovery Node — как у остальных нод, см.
`app/node_registration.py`.
