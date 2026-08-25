# OUO Sphinx sidecar

Локальный Unix-socket provider для `ouo-onion-sidecar/1`. Он использует
`nym-sphinx-types 1.21.5` / `sphinx-packet 0.6.0`, а не реализует onion crypto
самостоятельно.

Реализованный первый срез:

- `build` для маршрута Relay…Relay→Home длиной 2–5;
- `unwrap` с проверкой Sphinx header/payload и выдачей per-hop replay tag;
- `build_reply` из одноразового OUO-wrapped Nym SURB;
- `create_reply_block` для генерации endpoint-side одноразового SURB;
- systematic Reed-Solomon `erasure_encode` / `erasure_reconstruct` с
  `2 <= K <= N <= 64`, 4 MiB container и 1 MiB shard bounds;
- fixed packet classes 4/16/64/256 KiB;
- self-certifying OUO NodeID напрямую кодируется в 32-byte Sphinx address;
- expiry и capability следующего hop находятся в MAC-authenticated Sphinx
  delay field; реальный jitter выполняет Mix Pool;
- final expiry находится внутри многослойно защищённого payload;
- приватный transport key zeroize-обёрнут на время операции;
- только Unix socket, framing ограничен 12 MiB, erasure binary budget — 8 MiB,
  существующий путь не заменяется.

OUO SURB wrapper имеет бинарный формат `OUOSURB1 || expiry_ms:u64be ||
packet_class:u32be || nym_surb`. `create_reply_block` формирует его, а
`build_reply` строго потребляет и не принимает произвольный raw SURB. Доставка
этого блока контакту подключается отдельным E2EE endpoint-механизмом.

Reed-Solomon shards содержат кодированный framing `OUORS001`, K/N и исходную
длину. Это проверка формата, не authenticity: до encode container обязан быть
защищён endpoint AEAD, а после reconstruction AEAD обязательно проверяется.

Provider должен оставаться выключенным в production-конфигурации до сборки, conformance/fuzz
проверок и отдельного security gate.

Запуск после установки Rust 1.87+:

```bash
OUO_SPHINX_SOCKET=/run/ouo/sphinx.sock cargo run --release
```

`Cargo.lock` намеренно не создан вручную: его должен сформировать Cargo из
зафиксированных direct dependencies, после чего lockfile и checksums подлежат
review и коммиту.
