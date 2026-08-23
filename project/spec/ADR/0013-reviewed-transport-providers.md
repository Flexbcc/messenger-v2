# ADR-0013: Reviewed Rust providers для Sphinx и K-of-N

## Статус

Proposed — integration boundary реализована, зависимости не установлены.

## Решение

FastAPI-ноды не реализуют packet cryptography или Reed-Solomon самостоятельно.
Provider работает отдельным Rust process за Unix socket `0600` и общается по
bounded length-prefixed `ouo-onion-sidecar/1`. Соединение persistent, запросы
имеют UUID binding и timeout; неизвестные/ошибочные ответы fail closed.

Кандидат Sphinx для conformance spike: поддерживаемый Apache-2.0 проект Nym
Sphinx и его crate `nym-sphinx`. Он предоставляет packet builder/processor,
X25519 keys, replay tag и SURB concepts:

- https://github.com/nymtech/sphinx
- https://docs.rs/nym-sphinx

Кандидат K-of-N: Rust `reed-solomon-erasure` с отдельной обязательной AEAD/hash
проверкой каждого shard и reconstructed container:

- https://github.com/rust-rse/reed-solomon-erasure
- https://docs.rs/reed-solomon-erasure

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
