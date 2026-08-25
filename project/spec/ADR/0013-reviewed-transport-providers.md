# ADR-0013: Reviewed Rust providers для Sphinx и K-of-N

## Статус

Proposed — integration boundary и provider source реализованы, зависимости не
собраны и conformance/security gates не пройдены.

## Решение

FastAPI-ноды не реализуют packet cryptography или Reed-Solomon самостоятельно.
Provider работает отдельным Rust process за Unix socket `0600` и общается по
bounded length-prefixed `ouo-onion-sidecar/1`. Соединение persistent, запросы
имеют UUID binding и timeout; неизвестные/ошибочные ответы fail closed.

Выбранный Sphinx provider: поддерживаемый Apache-2.0 проект Nym, crate
`nym-sphinx-types = 1.21.5` (`sphinx-packet = 0.6.0`). Он предоставляет packet builder/processor,
X25519 keys, replay tag и SURB concepts:

- https://github.com/nymtech/sphinx
- https://docs.rs/nym-sphinx

Выбранный K-of-N provider: Rust `reed-solomon-erasure = 6.0.0` (MIT) с отдельной обязательной AEAD/hash
проверкой каждого shard и reconstructed container:

- https://github.com/rust-rse/reed-solomon-erasure
- https://docs.rs/reed-solomon-erasure

Crates.io archive checksums, которые должны совпасть с будущим `Cargo.lock`:

- `nym-sphinx 1.21.5`: `77657434dfc9954c74e90620a7f8b0acd32c8ce6fcb89dffe678ae010e182b05`;
- `reed-solomon-erasure 6.0.0`: `7263373d500d4d4f505d43a2a662d475a894aa94503a1ee28e9188b5f3960d4f`.

## Gate до активации

1. Pin exact source revision/crate versions и Cargo.lock.
2. Проверить license/dependency tree и security advisories.
3. Сопоставить OUO 4/16/64/256 KiB geometry с provider overhead.
4. Known-answer/conformance vectors build→unwrap→SURB.
5. Подтвердить tagging/replay behavior и zeroization private material.
6. Fuzz sidecar framing и Rust parsers.
7. Independent review до security claim.

До прохождения gate `ONION_PROVIDER_MODE=off`; `/mix/ingress` отвечает 503, а
Basic Relay продолжает работать отдельно.
