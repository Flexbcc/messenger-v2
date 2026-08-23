# 0224 — Opaque Offline Mailbox v1

## Назначение

Storage хранит endpoint-encrypted fixed-size cells по непрозрачной 256-bit
mailbox capability. В новой таблице нет UserID, DeviceID, conversation ID,
sender или E2EE MessageID.

Mailbox token создаётся CSPRNG либо выводится HMAC-SHA256 из независимого
endpoint/Home secret, mailbox scope и epoch. Storage не получает этот secret и
не способен восстановить identity по token. Rotation epoch создаёт новый token.

## API

Все endpoints требуют signed federation admission и Capability `home`:

- `POST /mailbox/store` — token, base64 fixed cell, bounded TTL;
- `POST /mailbox/fetch` — token и bounded `limit` (default 8, max 32) в signed
  body, не URL; ответ сообщает `has_more`;
- `POST /mailbox/ack` — token + storage-local entry UUID.

Storage декодирует только outer base64 и проверяет размер класса 4/16/64/256
KiB. Он не имеет cell key, не различает REAL/DUMMY и не открывает payload.
Одинаковый ciphertext в одной mailbox идемпотентен по локальному hash. ACK без
соответствующей mailbox capability не удаляет entry.

Raw mailbox token после запроса не сохраняется: Storage индексирует mailbox по
SHA-256 от 256-bit capability. Preimage остаётся практически недоступным, а
утечка БД не даёт непосредственно использовать сохранённое значение как bearer
token. Legacy rows мигрируют добавлением hash без удаления ciphertext.

Quota ограничена на token, expired rows очищаются, а health endpoint публикует
только aggregate count/bytes без top recipient identifiers. Общая storage
capacity проверяется внутри той же `BEGIN IMMEDIATE` transaction, что и insert,
поэтому параллельные записи не обходят disk budget.

## Migration

Legacy `/buffer/{recipient_device_id}` сохранён для совместимости и остаётся
metadata gap. Новый API пока не включён в Home/client delivery path: для этого
endpoint должен создавать fixed cell до передачи инфраструктуре и безопасно
распространять/ротировать mailbox capability.

## Replication client

`OpaqueMailboxClient` записывает одинаковую endpoint-encrypted cell на
настроенный replication set параллельно и считает операцию успешной только при
write quorum. Fetch опрашивает Storage независимо, локально проверяет fixed-size
encoding, объединяет копии по ciphertext hash и сохраняет отдельные receipt для
ACK каждой реплики. Недоступность одной Storage не меняет bearer capability и
не раскрывает identity. ACK возвращает список не подтверждённых replica
receipts, чтобы endpoint мог повторить только оставшиеся удаления.
