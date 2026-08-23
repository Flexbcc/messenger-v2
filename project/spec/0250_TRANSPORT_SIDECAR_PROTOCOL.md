# 0250 — Reviewed Transport Sidecar Protocol v1

Криптографический packet/erasure provider изолирован в локальном Rust sidecar.
Python-нода соединяется с ним только через Unix socket с правами `0600`.
TCP, shell invocation на пакет и динамическая загрузка библиотек не являются
частью контракта.

## Framing

Каждый frame: unsigned 32-bit big-endian JSON length, затем ровно JSON bytes.
Request и response ограничены 2 MiB. Соединение persistent, запросы строго
последовательны на одном соединении. Ошибка framing закрывает соединение.
Node lifecycle явно закрывает socket на shutdown; повторный runtime start
использует тот же immutable provider configuration и создаёт новое соединение
по требованию, не заменяя provider после появления Mix runtime.

Общие request fields:

```json
{
  "protocol_version": "ouo-onion-sidecar/1",
  "request_id": "UUIDv4",
  "operation": "build|unwrap|build_reply|erasure_encode|erasure_reconstruct"
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
  один из классов 4/16/64/256 KiB. Expiry входит в authenticated per-hop data.
- `unwrap`: 32-byte private key и fixed-size packet; возвращает 16–64-byte
  `replay_tag_b64` и ровно один вариант: next node + authenticated expected
  capability + next fixed-size packet либо final payload до 96 KiB, а также
  аутентифицированный `expires_at`.
- `build_reply`: one-time SURB до 256 KiB и payload; возвращает только первый
  ingress NodeID, fixed-size packet и expiry, зафиксированный внутри SURB.
  Реальный destination route не раскрывается.

Python повторно валидирует все размеры и взаимоисключающие варианты результата,
даже если sidecar считается локальным.

## Erasure operations

`2 <= K <= N <= 64`, исходный container не более 4 MiB, shard не более 1 MiB.
Encode обязан вернуть ровно N индексированных shards. Reconstruction принимает
не менее K уникальных индексов и shards одинакового размера. AEAD целостность
проверяется после reconstruction на endpoint; codec не является authentication.

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
