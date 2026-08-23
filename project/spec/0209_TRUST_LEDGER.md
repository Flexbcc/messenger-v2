# 0209. Trust Ledger v1

## Статус
Implemented locally — signed TrustRecord, chain/equivocation SQLite store,
Discovery report/enforce endpoint и D1/D2/D3 bounded pull-gossip реализованы.
5-of-7 меняет legacy projection; valid quorum conflict включает persistent
Safe Mode. Production authority provisioning остаётся pending.

## TrustRecord

TrustRecord фиксирует одно решение над Node Level:

- `promotion`;
- `degradation`;
- `suspension`;
- `reinstatement`;
- `revocation`.

Запись содержит subject NodeID, previous/new level, subject-local `epoch`,
отдельный `authority_epoch`, commitment на набор внешних evidence, externally
selected committee, threshold, hash предыдущей записи, timestamp и validator
signatures.

Подписи создаются над:

```text
"OUO/TRUST_RECORD/v1\0" || canonical_json(record_without_signatures)
```

Public keys валидаторов приходят из Authority State, а не из TrustRecord.

## Семантика действий
- `promotion`: `new_level > previous_level`;
- `degradation`: `new_level < previous_level`;
- `suspension`: уровень не изменяется;
- `reinstatement`: уровень не изменяется и требует непосредственно
  предшествующую suspension в следующем subject-local epoch;
- `revocation`: `new_level = L0`.

В v1 `revocation` является terminal state. После `suspension` разрешён только
явный quorum `reinstatement` или `revocation`; тихая promotion/degradation и
admin reinstate не считаются recovery. После reinstatement обычные transitions
снова разрешены.

## Цепочка
`previous_hash` равен SHA-256 предыдущего полного canonical TrustRecord.
`epoch` для одного subject после первого checkpoint возрастает строго на один.
Первая локально известная запись
имеет `previous_hash = null`, если она не является явно доверенным checkpoint.
`authority_epoch` указывает historical committee, которым подписано решение.
Несколько последовательных переходов subject могут происходить при одном
authority set; смена governance committee не ломает subject-local chain.

## Equivocation
Две разные валидные записи для одного `(subject_node_id, epoch)` являются
конфликтом. Общий validator, подписавший обе записи, оставляет проверяемое
доказательство equivocation.

Reference store не заменяет конфликтующую запись: сохраняет исходную запись и
отдельное evidence конфликта.

## Admission и historical events

В `TRUST_LEDGER_MODE=enforce` effective suspension/revocation запрещает:

- повторную registration и heartbeat;
- portable observer live work;
- публикацию/использование NodeAdvertisement в Discovery gossip.

Legacy admin `approve/reinstate/re-enroll/grandfather` не может снять quorum
deny. В enforce mode ручные `promote/demote` отключены: изменение Level требует
quorum TrustRecord. Локальные admin suspend/compromise остаются допустимым
дополнительным deny, но не authority для повышения.

Проверка сканирует весь validated chain: более поздняя promotion не может
стереть terminal deny. ACK/TrustObservation, подписанные до `decided_at`, могут
быть реплицированы позже как historical evidence; во временном окне suspension
новый live доступ запрещён. После quorum reinstatement live доступ
восстанавливается, но событие, созданное во время suspension, не становится
валидным задним числом. Локальная admin suspension без quorum не получает это
historical исключение.

## Ограничения текущего шага
- Authority State bootstrap задаётся provisioned конфигом, последующие epochs
  реплицируются AuthorityCheckpoint chain;
- reinstatement относится только к suspension; revocation terminal и требует
  нового NodeID согласно `0239`;
- production BFT finality/validator ceremony не развёрнуты;
- metrics commitment не раскрывает пользовательские маршруты или сообщения.

## Reference implementation
- `shared/security/trust_ledger.py`
- `services/discovery-node/app/routers/registry.py`
- `services/discovery-node/app/trust_admission.py`
- `services/discovery-node/app/trust_record_gossip.py`
- `tests/security/test_trust_ledger.py`
- `tests/integration/test_discovery_trust_ledger.py`
