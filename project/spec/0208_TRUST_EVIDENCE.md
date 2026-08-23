# 0208. External Trust Evidence и committee selection v1

## Статус
Draft v1 — signed observation, deterministic committee, runtime challenge
runner и bounded Discovery persistence реализованы. Random observer assignment,
reputation aggregation и authority randomness ещё не подключены.

## Назначение
Нода не повышает доверие на основании собственной telemetry. Reliability
evidence создаётся внешним observer после synthetic challenge либо другого
независимо проверяемого события.

## ReliabilityObservation v1

Поля:

- `protocol_version = ouo-trust-observation/1`;
- `object_version = 1`;
- `observation_id` — UUID;
- `observer_node_id`, `subject_node_id` — разные self-certifying NodeID;
- `epoch`;
- `challenge_type` — `relay_delivery`, `storage_store_get`,
  `discovery_lookup`, `availability`;
- `challenge_commitment` — SHA-256 commitment, не пользовательский ID;
- `result` — `success`, `failure`, `invalid`;
- `latency_bucket` — `lt_20ms`, `20_50ms`, `50_100ms`, `100_250ms`,
  `250_1000ms`, `gte_1000ms`, `none`;
- `observed_at`, `expires_at` — срок evidence не более 24 часов;
- `signature` — Ed25519 observer signature.

Object запрещает дополнительные поля, поэтому в него нельзя незаметно
добавить UserID, conversation ID или полный route.

## Domain separation

```text
"OUO/TRUST_OBSERVATION/v1\0" || canonical_json(observation_without_signature)
```

## Verification
- observer key приходит из проверенного Node/Capability state;
- self-observation запрещено;
- unknown/revoked/expired observer отклоняется;
- signature, time window, epoch и exact schema проверяются fail closed;
- duplicate `observation_id` и повтор commitment отсекаются Discovery
  persistence/replay store.

## Committee selection v1
Committee выбирается не candidate, а детерминированно из externally supplied:

- quorum-approved randomness seed;
- authority epoch;
- полного eligible validator set.

Для каждого eligible validator вычисляется SHA-256 score с domain separation;
берутся первые N. Candidate исключается. Одинаковые входные данные дают один
committee для всех verifier.

Randomness seed сам должен быть частью quorum-signed Authority State. Этот
документ не определяет генерацию randomness.

## Не входит в этот шаг
- веса reputation;
- observer diversity/ASN policy;
- randomized challenge scheduler и observer diversity assignment;
- Trust Ledger и promotion transaction.

## Reference implementation
- `shared/security/trust_evidence.py`
- `shared/security/synthetic_challenge.py`
- `shared/security/committee_selection.py`
- `services/discovery-node/app/trust_observation_store.py`
