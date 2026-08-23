# 0219 — Quorum-signed ChallengeAssignment v2

`ChallengeAssignment` связывает externally selected observers с конкретной
subject нодой, challenge type и epoch. Объект содержит:

- version, assignment UUID;
- subject и sorted observer NodeIDs;
- challenge type/epoch;
- commitment на quorum-approved randomness;
- отдельные challenge `epoch` и `authority_epoch`;
- bounded `not_before`/`expires_at` (не более часа);
- validator committee, threshold и previous hash;
- validator signatures.

Verifier получает Authority State независимо от publisher. Для начальной policy
требуется 5-of-7; duplicate, outside-committee, revoked и expired signatures не
учитываются. 4-of-7 недостаточно. Observer selection выполняется до подписания;
В enforce mode Discovery независимо загружает replicated quorum-signed
RandomnessCheckpoint (`0236`), повторяет selection и только затем проверяет
подписи assignment. Quorum-подпись неправильного observer set недостаточна.

## Discovery lifecycle

Discovery хранит assignment идемпотентно и запрещает два разных quorum-объекта
для одинаковых `(subject_node_id, challenge_type, epoch)`. Такой конфликт
переводит control plane в Safe Mode.

Назначенный observer получает объект через authenticated pull. Состояния:

```text
pending -> accepted -> completed
       \-> declined
pending/accepted -> expired
```

`accepted` и `declined` устанавливаются только после проверки подписанного
`ChallengeAssignmentAck`. ACK связан с assignment UUID, NodeID observer,
decision и timestamp; его подписывает текущий Operational Key observer.

`completed` нельзя выставить отдельной telemetry-командой. Discovery переводит
observer assignment в `completed` только при приёме валидного signed
`TrustObservation`, совпадающего по observer, subject, challenge type и epoch.
Для observation v1 связь с assignment UUID находится в authenticated publish
envelope; сами reliability evidence остаются privacy-minimized.

## API v2

- `POST /registry/challenge-assignments` — quorum validation + persistence;
- `GET /registry/challenge-assignments/{observer_node_id}` — authenticated pull;
- `POST /registry/challenge-assignment-acks` — signed observer ACK;
- `POST /registry/trust-observations` с optional `assignment_id` — verified
  completion.

Immutable assignment objects реплицируются между D1/D2/D3 по `0232`, а
Operational-Key portable observer pull/ACK определён в `0233`.
Signed ACK и assignment-bound TrustObservation/completion реплицируются по
`0234` и `0235`. Quorum-signed randomness checkpoint и proposal-only scheduler
определены в `0236`; автоматическая cadence, threshold-VRF и missed-job
penalties остаются следующими этапами. До них отсутствие ACK или observation
не повышает reputation автоматически и не считается доказуемым security
violation.
