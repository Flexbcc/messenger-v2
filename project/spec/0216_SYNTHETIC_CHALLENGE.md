# 0216 — Synthetic Challenge и TrustObservation v1

## Назначение

Observer выполняет проверяемое data-plane действие над другой нодой и выпускает
подписанный privacy-minimized `TrustObservation`. Подпись доказывает только факт
утверждения observer, а не абсолютную истинность результата.

## Выполнение

`SyntheticChallengeRunner` создаёт через CSPRNG 32-byte secret и commitment:

```text
SHA-256(
  "OUO/SYNTHETIC_CHALLENGE/v1\0" ||
  secret || challenge_id || observer_node_id || subject_node_id || type || epoch
)
```

Secret, mailbox token, packet data, exception и маршрут остаются локальными.
Публикуются только поля `TrustObservation` из `0208_TRUST_EVIDENCE.md`:

- self-certifying observer/subject NodeID;
- epoch и challenge type;
- commitment;
- success/failure;
- coarse latency bucket;
- bounded timestamps;
- operational signature observer.

## Discovery admission

Перед криптографической проверкой Discovery требует:

- известную и trusted observer Node Identity;
- node token в strict enrollment mode;
- известную subject Node Identity;
- размер object не более 16 KiB;
- не более 1 000 активных observations на observer.

Затем проверяются operational credential, signature, expiry, external observer
и exact schema. `observation_id` и `(observer, challenge_commitment)` защищены
unique constraints; exact повтор идемпотентен, конфликт/replay отклоняется.

## Реализованный scope

Локальный cluster выполняет:

- реальный Relay delivery challenge;
- реальный Storage STORE/GET/hash verification/ACK-delete challenge;
- публикацию двух подписанных observations в Discovery.

Randomized observer assignment, multi-observer aggregation, reputation weights
и promotion policy остаются следующими шагами.
Реальный пользовательский traffic не используется как доказательство обвинения.
