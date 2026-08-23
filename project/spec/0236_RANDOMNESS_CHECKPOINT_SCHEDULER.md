# Quorum RandomnessCheckpoint and proposal scheduler v1

Status: `implemented locally`

## Purpose

The subject node must not choose its challenge observers, and a Discovery must
not accept an arbitrary caller-provided seed. A `RandomnessCheckpoint` fixes the
selection input and eligible observer snapshot under the exact authority
quorum that governed it.

## Signed checkpoint

The versioned object contains:

- monotonically chained `challenge_epoch`;
- independent `authority_epoch`;
- previous checkpoint hash (the first checkpoint anchors to the authority-state
  hash);
- 32-byte randomness seed;
- sorted eligible observer NodeIDs and authority-supplied diversity groups;
- observer-count policy;
- validity window, committee and threshold;
- validator signatures.

The checkpoint hash excludes signatures and uses domain-separated canonical
JSON. Therefore signature encoding cannot be ground to change the scheduling
seed or observer ranking.

## Persistence and replication

```text
POST /registry/randomness-checkpoints
GET  /registry/randomness-checkpoints/gossip
POST /registry/randomness-checkpoints/gossip
```

D1/D2/D3 independently validate the exact historical authority set, quorum,
chain, epoch, time window, eligible snapshot and object hash. Conflicting
quorum checkpoints for one challenge epoch freeze governance. Pull is bounded
and replays idempotently from local checkpoints.

## Proposal-only scheduler

`build_challenge_assignment_proposal` accepts only public validated state. It
has no validator-key argument and emits an unsigned ChallengeAssignment v2.
The proposal separates:

- `epoch` — challenge/randomness epoch;
- `authority_epoch` — committee epoch;
- `randomness_commitment` — validated checkpoint hash.

Observers are deterministically selected with domain-separated SHA-256. The
subject is excluded and distinct authority-supplied diversity groups are
preferred. Assignment ID также детерминированно выводится из checkpoint,
subject, challenge type, временного окна и previous hash, поэтому независимые
валидаторы получают один signing payload. Validators sign the proposal
separately. In enforce mode every
Discovery recomputes the observer set and rejects even a 5-of-7 signed
assignment if it does not match the checkpoint.

Discovery сериализует admission и проверяет отдельную hash-chain назначений
для каждой пары subject/challenge type. Разрыв `previous_hash`, вставка старого
epoch и конкурентная попытка построить fork отклоняются.

## Автоматический proposal runtime

В режимах `report/enforce` Discovery для каждого
актуального checkpoint детерминированно создаёт unsigned proposals:

- `availability` для каждой trusted Node Identity;
- `relay_delivery`, `storage_store_get` и `discovery_lookup` только для
  соответствующей certified Capability;
- временное окно выводится из quorum checkpoint и не зависит от локальных
  часов конкретной Discovery;
- повторный цикл идемпотентен, конфликт детерминированного proposal fail closed.

Proposals сохраняются отдельно от assignments и доступны валидаторам через
`GET /registry/challenge-assignment-proposals`. Только после quorum signatures
объект принимается обычным assignment endpoint и начинает исполняться.
В `enforce` полный signing payload обязан совпасть с локальным proposal;
signatures сравниваются отдельно обычной quorum validation.

Истёкший неподписанный proposal получает статус `missed`. Это сигнал
доступности validator/control plane и не снижает reputation проверяемого
subject: отсутствие assignment не доказывает отказ самой ноды.
Runtime также глобально переводит просроченные `pending/accepted` observer jobs
в `expired`, даже если observer больше никогда не выполняет pull. Это устраняет
зависшие задания, но не создаёт фиктивный TrustObservation от имени observer.

## Deployment mode

`RANDOMNESS_CHECKPOINT_MODE` supports `off`, `report` and `enforce`. Secure
deployment starts in report mode, provisions/converges a quorum checkpoint,
then switches all Discovery replicas to enforce. Enforce requires the bounded
ChallengeAssignment lifecycle gossip peer set.

## Verified behavior

- 4-of-7 checkpoint is rejected; 5-of-7 is accepted;
- seed, eligible snapshot, authority, previous hash and epoch tamper fail;
- a quorum-signed wrong observer set is rejected by external recomputation;
- conflicting checkpoint freezes governance;
- the eight-process cluster converges checkpoint D1→D2/D3 before assignment,
  then completes the portable challenge lifecycle.

## Residual risk

The v1 seed is quorum-approved and publicly verifiable, but it is not a
threshold VRF and does not prove absence of validator seed grinding. Production
hardening requires a reviewed external beacon, threshold-VRF, or commit/reveal
construction with explicit liveness and abort-bias analysis. Automatic cadence,
missed-job penalties and validator signing transport are also not implemented.
