# 0246 — Multipath и K-of-N Provider Boundary v1

Multipath planner распределяет до 64 shard indices по максимум восьми путям,
предпочитает node-disjoint routes и не уменьшает hop count при дефиците Relay.

K-of-N codec отделён интерфейсом `ErasureCodecProvider`, параметры ограничены
`2 <= K <= N <= 64`. Встроенного самодельного Reed-Solomon нет: без выбранной и
рассмотренной библиотеки encode/reconstruct fail closed. Простая нарезка N/N не
выдаётся за K-of-N и не создаёт ложного свойства отказоустойчивости.

Rust sidecar adapter реализует bounded async operations `erasure_encode` и
`erasure_reconstruct`. Python повторно проверяет K/N, уникальность индексов,
одинаковый размер shards и memory limits. Целостность reconstructed container
обязательно подтверждается endpoint AEAD: Reed-Solomon не является
authentication mechanism.
