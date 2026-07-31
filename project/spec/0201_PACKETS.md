# 0201. Пакеты

## Статус
Draft (R2) — логическая семантика Packet + serialization profile **`mvp-json`**.  
Сверка: [`docs/reality/R2-wire-today.md`](../../docs/reality/R2-wire-today.md).  
Envelope MVP: [`project/shared/README.md`](../shared/README.md).

## Назначение
Формат Packet ([[0004_GLOSSARY]]): заголовки, сериализация, лимиты,  
и явное отображение на LIVE HTTP/JSON/WS.

---

## Два уровня

| Уровень | Что описывает | Статус |
|---------|---------------|--------|
| **Логический Packet** | Поля и типы ниже — контракт смысла | to-be + частичный MVP |
| **`mvp-json`** | JSON envelope / REST / WS events | LIVE канон |
| **binary (protobuf и т.п.)** | Компактный wire | будущий MAJOR |

Формат сериализации не является единственным обязательным контрактом:
допустима любая реализация с тем же каноническим смыслом полей
(Protocol Before Implementation). Референс будущего binary — Protocol Buffers.

---

## Структура логического пакета

| Поле | Тип | Обязательное | Описание |
|---|---|---|---|
| `version` | uint16 (`MAJOR.MINOR`) | да (to-be) | версия протокола, [0200](0200_PROTOCOL.md) |
| `type` | enum | да | тип пакета (см. ниже) |
| `packet_id` | 128-bit UUID | да | дедупликация, [0202](0202_DELIVERY.md) |
| `session_id` | 128-bit UUID | да (to-be) | Session после handshake |
| `sender_ref` | opaque token | нет | маршрутизируемый id без прямой Identity |
| `timestamp` | int64 unix ms | да | время создания отправителем |
| `payload` | bytes | да | E2EE полезная нагрузка |
| `signature` | bytes Ed25519 | да (to-be hop) | подпись отправляющим узлом |
| `ttl` | uint | нет | оставшийся срок жизни маршрута/пакета (R4) |
| `compression` | enum | нет | сжатие payload до шифрования — вне MVP |
| `routing` | opaque | нет | подсказки следующего хопа (R4) |
| `checksum` | bytes | нет | целостность на hop; в MVP часто = HTTP/TLS |

### Типы пакетов

| `type` | Назначение |
|---|---|
| `MESSAGE` | доставка Message |
| `ACK` | подтверждение получения/обработки |
| `HANDSHAKE` | установление Session |
| `PRESENCE` | доступность устройства (опционально) |
| `DISCOVERY_QUERY` / `DISCOVERY_RECORD` | resolve адреса, [0604](0604_DISCOVERY_NODE.md) |
| `CONTROL` | служебные операции (устройства, ключи, смена Home) |

---

## Profile `mvp-json`: Message Envelope

Временная JSON-сериализация (имена полей близки к логическим, чтобы смена
сериализации не ломала модель):

```json
{
  "packet_id": "uuid",
  "type": "MESSAGE",
  "conversation_id": "uuid",
  "sender_user_id": "uuid",
  "sender_device_id": "uuid",
  "crypto_version": "signal-v1",
  "ciphertext": "base64",
  "content_type": "text | image | file | voice",
  "created_at": "ISO-8601"
}
```

### Mapping: логический Packet ↔ mvp-json envelope

| Логическое поле | mvp-json | Примечание |
|-----------------|----------|------------|
| `version` | — | нет; есть `crypto_version` |
| `type` | `type` | LIVE в основном `MESSAGE` |
| `packet_id` | `packet_id` | да |
| `session_id` | — | JWT на транспорте, не в envelope |
| `sender_ref` | `sender_user_id` + `sender_device_id` | слабее приватности маршрута |
| `timestamp` | `created_at` | ISO string вместо unix ms |
| `payload` | `ciphertext` | base64 |
| `signature` | — / federation headers | hop-sig не в envelope; опционально `X-Federation-*` |
| `ttl` | — | нет |
| — | `conversation_id`, `content_type` | прикладные поля MVP |

`ciphertext` для серверов — непрозрачный blob.

---

## Profile `mvp-json`: тип пакета ↔ endpoint / событие

| Логический `type` | LIVE механизм | Путь / событие |
|-------------------|---------------|----------------|
| **MESSAGE** | REST send + WS push + federation | `POST /conversations/{id}/messages`; WS `{type:"new_message", message: envelope}`; `POST /internal/deliver`; `POST /relay/forward`; storage `POST/GET/DELETE /buffer/...` |
| **ACK** | отсутствует | HTTP 200 ≠ semantic ACK; отдельного ACK packet нет |
| **HANDSHAKE** | REST auth | `POST /auth/register\|login\|challenge\|verify`; WS только проверяет JWT |
| **PRESENCE** | ad hoc | WS connect = online; `ping`/`pong`; опционально `typing`; `Device.last_active` |
| **DISCOVERY_*** | REST registry | `POST/GET /registry/users`, `GET /registry/users/{id}`, `GET /registry/users/search`, `POST/GET /registry/nodes`, heartbeat/enrollment; Gateway catalog/routing |
| **CONTROL** | REST россыпью | prekeys `/users/{id}/prekey-bundle`, `/devices/{id}/prekeys`; devices; `POST /security-signals`; storage pair; monitor |

Клиентский send path = **REST**; WS в основном **receive** (+ keepalive/typing).

---

## Ограничения размера

Референс to-be: max Packet ~64 КБ на мультиплексированном канале.  
Крупные файлы — не в Packet, а ссылка на Media Node ([0102_DATA_FLOW.md](0102_DATA_FLOW.md)).

В `mvp-json`: лимиты задаёт HTTP body / reverse proxy; отдельного packet TTL/size enforcement как в спеке может не быть.

---

## Обратная совместимость

- Логические поля идентифицируются по имени/номеру схемы; неизвестные — игнорировать.
- Семантика обязательного поля меняется только с новым `MAJOR`.
- `mvp-json` → binary: сохранять смысл `packet_id`, `type`, ciphertext, sender/device ids.

## Связанные документы

- [0200_PROTOCOL.md](0200_PROTOCOL.md) — handshake и profile
- [0202_DELIVERY.md](0202_DELIVERY.md)
- [0205_NODE_RECORD.md](0205_NODE_RECORD.md)
