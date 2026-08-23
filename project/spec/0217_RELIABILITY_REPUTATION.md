# 0217 — Reliability Reputation snapshot v1

## Назначение

Discovery строит детерминированную сводку только над ранее проверенными
`TrustObservation`. Сводка не является TrustRecord, capability certificate или
решением о promotion.

## Ограничение веса observer

В effective set входит максимум последнее observation для ключа:

```text
(observer_node_id, challenge_type, epoch)
```

Тысяча утверждений одной ноды об одном типе challenge в одном epoch поэтому не
получает тысячу голосов. Observation текущего suspended/compromised observer
остаётся в audit storage, но не входит в derived reliability view.

## Поля snapshot

- raw/trusted/effective observation counts;
- число уникальных observer NodeID;
- result, latency bucket и challenge type distributions;
- minimum/maximum epoch;
- целочисленный `success_rate_bps`;
- `observer_diversity = node_id_only_unproven`;
- current/proposed level and explicit unmet eligibility conditions;
- counts of assigned/completed/expired observer slots (absence is reported but
  не считается виной subject без подписанного результата challenge);
- canonical `evidence_commitment`;
- точные числовые параметры `eligibility_policy`, включённые в commitment;
- `promotion_decision = eligible_for_quorum_review | not_eligible`.

Решение является только детерминированным proposal. Оно требует минимального
числа effective observations, observers, типов challenge и success rate, а
`invalid` result блокирует eligibility. Ни snapshot, ни list endpoint не
изменяют Level/Capability: применить переход может только quorum TrustRecord.

Доступны:

- `GET /registry/trust-reliability/{subject_node_id}`;
- `GET /registry/trust-eligibility-candidates`.

## Следующие шаги

Randomized observer assignment и challenge history реализованы. Остаются
реальные operator/ASN/subnet diversity labels, quorum-versioned scoring policy
и отдельная Security Reputation для криптографически доказуемых нарушений.
