# Threat model

> Статус: **модель**. Не утверждается, что сеть невозможно взломать или что
> метаданные полностью скрыты.

## Допущения

Проектировать так, будто: Relay/Storage могут быть злонамеренными; Discovery может
быть скомпрометирован; часть нод контролирует один атакующий; пакеты могут
перехватываться, изменяться, повторно отправляться; злоумышленник сканирует
публичные адреса и запускает тысячи поддельных нод; пользователь долго не
обновляется; диск Home Node может быть украден; устройство пользователя может быть
скомпрометировано.

## Главные принципы

1. Взлом одной ноды **не** означает взлом сети.
2. Компрометация Home Node **не** раскрывает переписку автоматически.
3. Устаревшая нода **не** создаёт угрозу остальной сети.

## Защита публичного интерфейса

Публичный сканер до аутентификации не должен получать: версию, список
пользователей, файлов, маршрутов, внутреннюю конфигурацию, admin API,
диагностические данные, понятный protocol banner.

```
Public network → TLS/protected transport → minimal handshake →
cryptographic authentication → capability & role verification →
authorized protocol operations
```

Административный интерфейс — только локально / через доверенное устройство /
отдельный защищённый канал; наружу по умолчанию не публикуется.

## Криптография (без самодельных алгоритмов)

identity keys, device keys, signed node descriptors, authenticated encryption,
unique nonces, replay protection, message IDs, counters/timestamps, expiry, key
rotation, device/node revocation, verification fingerprints, attachment-specific
keys. Relay и Storage не имеют ключей содержимого. Разделение сущностей — см.
[storage-model](storage-model.md).

## Replay и подмена

Каждый объект: `message_id, sender_device_id, recipient_route_token, sequence,
nonce, created_at, expires_at, payload_hash, signature|AEAD, protocol_version`.
Нода отклоняет повторы, проверяет TTL и целостность, ограничивает размер и частоту,
не доверяет полям от клиента.

## Sybil

Уникальный ключ ≠ уникальный участник. Разделять: can connect / relay / store /
participate in discovery / influence routing / act as infrastructure. Неизвестная
нода не получает сразу критическую роль. Сигналы доверия: возраст, стабильность,
успешная история, независимые подтверждения, ограничение по подсетям, стоимость
публичной роли, resource proof, rate limits, постепенные квоты. Trust —
**контекстный** (relay/storage/discovery/availability/abuse), не один глобальный
балл-власть.

## Компрометация Home Node

- **Украден диск (A):** encrypted blobs + индексы + часть метаданных, но **не**
  ключи сообщений → содержимое не раскрывается автоматически.
- **Взломан работающий процесс (B):** риск выше; минимизировать время ключей в
  памяти, права процессов, доступ Storage к identity keys, доступ Relay к личным
  файлам, горизонтальное перемещение.
- **Взломано устройство (C):** самый серьёзный случай — E2EE **не** защищает от
  полностью скомпрометированного конечного устройства (честно фиксируем).

## Изоляция компонентов

```
UI Client · Identity · Messaging · Storage · Sync · Community Relay Worker ·
Update Service · Monitoring
```

Relay не читает User Library; Storage не получает ключи чатов; UI не имеет прямого
доступа к секретам; Update Service не имеет доступа к данным; Community Worker
ограничен ресурсами; публичный процесс изолирован от admin API.

## Метаданные (честно)

Relay видит время соединения, объём, IP соседних участников, длительность. Не
утверждаем, что метаданные полностью невидимы.

## Реализовано в визуализаторе

Сценарии: Network scan, Compromised relay (видит метаданные, не видит содержимого;
tamper/replay блокируются, маршрут переключается), Home Node compromise (disk vs
running), Sybil (низкие лимиты, без критических ролей, контекстное доверие).
