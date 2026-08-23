# 0213 — Network View и Control-plane Safe Mode

## Invariant

При противоречивых quorum-validated Authority checkpoints нода замораживает
promotion, authority/capability changes и governance. Existing E2EE sessions,
cached routes и достижимый data plane продолжают работать.

## State machine

`NetworkViewGuard` принимает только checkpoints, криптографическая проверка
которых уже выполнена предыдущим слоем. Он обнаруживает:

- разные checkpoint hashes одного authority epoch;
- разрыв `previous_hash` в последовательной цепочке;
- пропущенный промежуточный epoch;
- чрезмерный stale gap между тремя и более независимыми sources.

Safe Mode сохраняется атомарно с mode `0600` и переживает restart. Обычное
наблюдение не может автоматически снять freeze. Выход разрешён только через
явно quorum-verified recovery checkpoint с более высоким epoch.

## Интеграция

Guard подключён к governance endpoints Discovery, quorum-validated
AuthorityCheckpoint, authenticated D1/D2/D3 gossip и emergency recovery.
Gossip передаёт подписанный source `head`, поэтому известный локально stale
checkpoint учитывается как network-view observation, но не применяется как
rollback authority state.

Оставшееся ограничение — независимость операторов/сетей Discovery задаётся
deployment policy и должна подтверждаться на физическом стенде.
