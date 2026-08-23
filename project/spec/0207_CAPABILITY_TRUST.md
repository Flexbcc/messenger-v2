# 0207. Capability Certificate и quorum verification v1

## Статус
Implemented locally — verification, deterministic committee, Discovery
report/enforce, provisioned certificate loading, federation capability policy
и AuthorityCheckpoint D1/D2/D3 replication реализованы. Production genesis,
validator custody и certificate issuance ceremony ещё не проведены.

## Инварианты
- Identity, Level и Capability — разные сущности.
- Нода не выдаёт capability сама себе.
- Level определяет только eligibility; он не включает capabilities
  автоматически.
- Committee передаётся проверяющей стороне из доверенного Authority State.
  Candidate не выбирает committee через содержимое сертификата.
- Повторная подпись одного validator учитывается один раз.
- Expired/revoked validator не голосует.

## CapabilityCertificate v1

Подписываемая часть содержит:

| Поле | Назначение |
|---|---|
| `protocol_version` | `ouo-capability/1` |
| `object_version` | `1` |
| `certificate_id` | UUID |
| `subject_node_id` | self-certifying NodeID получателя |
| `level` | L0–L5, integer `0..5` |
| `capabilities` | явно выданные права |
| `quotas` | ресурсные ограничения |
| `epoch` | последовательный epoch сертификата конкретной ноды |
| `authority_epoch` | historical authority set, подписавший сертификат |
| `issued_at`, `valid_until` | bounded lifetime, не более 30 суток |
| `committee` | validator IDs, сверяются с externally selected set |
| `threshold` | требуемое число независимых подписей |
| `previous_hash` | связь с предыдущим control state или `null` |

Отдельное поле `signatures[]` содержит `{validator_id, signature}`. Validator
public keys не берутся из самого сертификата: verifier получает их из
проверенного Authority State.

## Domain separation

```text
Ed25519.sign(
  ValidatorPrivateKey,
  "OUO/CAPABILITY_CERT/v1\0" || canonical_json(certificate_without_signatures)
)
```

## Минимальная eligibility policy v1

| Capability | Минимальный level |
|---|---:|
| `home` | L0 |
| `relay` | L2 |
| `storage` | L4 |
| `gateway` | L4 |
| `turn` | L4 |
| `discovery` | L4 |
| `validator` | L5 |

Достижение уровня не выдаёт перечисленные capabilities автоматически.

## Quotas v1
Допустимы только bounded non-negative integers:

- `max_bandwidth_bps`
- `max_connections`
- `max_cells_per_epoch`
- `max_cover_bytes_per_epoch`
- `max_storage_bytes`

Неизвестные quota fields в v1 отклоняются fail closed.

## Validation
Verifier получает отдельно:

- `expected_committee`;
- `expected_threshold`;
- validator credentials с public key, expiry и revocation state;
- минимально допустимый subject epoch;
- ожидаемый authority epoch.

Сертификат принимается только при полном совпадении committee/threshold,
достаточном числе уникальных валидных подписей и выполнении всех structural,
expiry, eligibility и anti-rollback проверок.

После первого принятого сертификата Discovery хранит его content hash как head
цепочки конкретной ноды:

- идентичный certificate/epoch идемпотентен;
- другой валидно подписанный certificate того же epoch считается equivocation;
- следующий subject epoch обязан быть строго последовательным и ссылаться
  `previous_hash` на полный предыдущий
  certificate;
- infrastructure-нода обновляет certificate на каждом heartbeat;
- missing/expired/broken-chain certificate блокирует heartbeat и исключает
  ноду из обычного node/peer listing в enforce mode.

Advertisement observation gossip переносит тот же certificate между
Discovery. Каждая D1/D2/D3 независимо ведёт `capability_certificate_heads`.
После появления нового head старые observations остаются audit evidence, но не
участвуют в peer view. Candidate возвращается только когда минимум два
сертифицированных Discovery source подтвердили один текущий head. Конфликт двух
quorum certificates одного subject/epoch сохраняется отдельно и замораживает
governance через API boundary.

## Остаётся
- reviewed threshold-VRF/external randomness source;
- production synthetic-challenge cadence и reputation weights;
- production finality/operator-diversity policy между Discovery;
- production provisioning/revocation ceremony.

## Reference implementation
- `shared/security/capability_certificate.py`
- `shared/security/capability_enrollment.py`
- `tests/security/test_capability_certificate.py`
- `tests/integration/test_discovery_node_identity.py`
- `services/discovery-node/app/node_advertisement_gossip.py`
- `tests/integration/test_discovery_node_advertisement_gossip.py`

## Secure runtime policy

Базовый compose сохраняет `report` только для совместимой локальной миграции.
`docker-compose.secure.yml` всегда включает:

- `CAPABILITY_CERTIFICATE_MODE=enforce` на Discovery;
- `FEDERATION_CAPABILITY_MODE=enforce` на data-plane нодах;
- отдельный `/data/capability_certificate.json` для каждой infrastructure role.

L0 Home без infrastructure certificate может обслуживать собственных клиентов.
Самодекларация `relay`, `storage`, `discovery`, `gateway`, `turn`, `media` или
`validator` не даёт права регистрации или вызова защищённого data-plane.
