# 0250 — Reviewed Transport Sidecar Protocol v1

Криптографический packet/erasure provider изолирован в локальном Rust sidecar.
Python-нода соединяется с ним только через Unix socket с правами `0600`.
TCP, shell invocation на пакет и динамическая загрузка библиотек не являются
частью контракта.

## Framing

Каждый frame: unsigned 32-bit big-endian JSON length, затем ровно JSON bytes.
Request и response ограничены 12 MiB. Для erasure дополнительно ограничена
сумма binary shard bytes до base64-кодирования — 8 MiB. Соединение persistent, запросы строго
последовательны на одном соединении. Ошибка framing закрывает соединение.
Node lifecycle явно закрывает socket на shutdown; повторный runtime start
использует тот же immutable provider configuration и создаёт новое соединение
по требованию, не заменяя provider после появления Mix runtime.

Общие request fields:

```json
{
  "protocol_version": "ouo-onion-sidecar/1",
  "request_id": "UUIDv4",
  "operation": "build|unwrap|build_reply|create_reply_block|erasure_encode|erasure_reconstruct"
}
```

Response обязан повторить `protocol_version` и `request_id`, а также вернуть
`ok: true`. Неизвестная операция, версия или поле критического объекта
отклоняются fail closed. Тексты ошибок наружу data plane не передаются.

## Onion operations

- `build`: route из 2–5
  `{node_id, capability=relay|home, public_key_b64}`, payload до 96 KiB;
  первые layers имеют capability `relay`, последняя и единственная — `home`;
  caller передаёт timezone-aware `expires_at`, а результат `packet_b64` имеет
  один из классов 4/16/64/256 KiB. NodeID v1 декодируется в исходный 32-byte
  SHA-256 digest и непосредственно используется как Sphinx node address.
  Expiry и capability следующего hop кодируются в MAC-authenticated 64-bit
  Sphinx delay field: старший бит означает `home`, остальные 63 бита — Unix
  milliseconds expiry. Реальную задержку задаёт Mix Pool, а не это поле.
- `unwrap`: 32-byte private key и fixed-size packet; возвращает 16–64-byte
  `replay_tag_b64` и ровно один вариант: next node + authenticated expected
  capability + next fixed-size packet либо final payload до 96 KiB, а также
  аутентифицированный `expires_at`.
- `build_reply`: one-time SURB до 256 KiB и payload; возвращает только первый
  ingress NodeID, fixed-size packet и expiry, зафиксированный внутри SURB.
  Реальный destination route не раскрывается.
  OUO wrapper имеет вид `OUOSURB1 || expiry_ms:u64be || packet_class:u32be ||
  nym_surb`; неизвестный или raw provider SURB отклоняется.
- `create_reply_block`: destination endpoint передаёт route, expiry и один из
  fixed packet sizes; получает opaque OUO-wrapped SURB. Route имеет те же
  Relay…Relay→Home ограничения и никогда не публикуется через Discovery.

Python повторно валидирует все размеры и взаимоисключающие варианты результата,
даже если sidecar считается локальным.

## Erasure operations

`2 <= K <= N <= 64`, исходный container не более 4 MiB, shard не более 1 MiB.
Encode обязан вернуть ровно N индексированных shards. Reconstruction принимает
не менее K уникальных индексов и shards одинакового размера. AEAD целостность
проверяется после reconstruction на endpoint; codec не является authentication.
Если `shard_size * N > 8 MiB`, операция отклоняется: формально допустимые K/N
не получают права на неограниченное memory/wire amplification.

## Process and key boundary

Node transport private key передаётся sidecar только для локальной операции
unwrap и никогда не включается в сеть или логи. Socket размещается в отдельном
runtime volume, не публикуется наружу. Adapter отклоняет symlink/обычный файл,
неверного владельца и group/world permissions. Sidecar работает без сетевого
доступа, с read-only root filesystem, resource limits и тем же выделенным
непривилегированным service UID, что нужен Python-процессу для socket `0600`.

Конкретные crates, версии и hashes принимаются только после gates ADR-0013:
dependency/license review, known-answer/conformance tests, fuzzing и независимый
security review. До этого `ONION_PROVIDER_MODE=off`, а Mix ingress fail closed.

Первый provider slice реализует `build`, `unwrap` и потребление SURB через
`build_reply`, `create_reply_block`, а также bounded Reed-Solomon
encode/reconstruct. Endpoint-доставка SURB внутри E2EE остаётся отдельной
интеграцией клиентского слоя.
