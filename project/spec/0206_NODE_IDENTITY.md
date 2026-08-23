# 0206. Node Identity и Operational Certificate

## Статус
Draft v1 — primitives, persistent credentials, explicit operational rotation,
registration и Discovery persistence реализованы. Root-signed distributed
credential high-watermark реализован по `0237` для portable observer path.
Serial-specific quorum revocation реализован по `0238`, automatic node-side
state chain — по `0237`. Окончательное удаление legacy alias и Node Root
transition ещё не включены.
До появления precommitted recovery policy действует fail-closed граница
`0239`: новый Root означает новый L0 NodeID без переноса прав.

## Назначение
Задать постоянную криптографическую идентичность ноды отдельно от её текущего
сетевого адреса, operational key, уровня доверия и capabilities.

## Ключи

```text
Node Root Key (долгоживущий, используется редко)
└── Operational Key (короткоживущий сертификат, подписывает runtime traffic)
```

Node Root private key не публикуется и не используется для обычных federation
requests. Operational key допускает регулярную ротацию без изменения NodeID.

## NodeID v1

```text
digest = SHA-256(raw 32-byte Ed25519 Node Root public key)
node_id = "ouo-node-v1-" + lowercase-base32-no-padding(digest)
```

NodeID является self-certifying: получатель пересчитывает его из root public
key. Человекочитаемые имена (`home-a`) остаются label/alias и не являются
security identity.

## OperationalCertificate v1

| Поле | Тип | Смысл |
|---|---|---|
| `protocol_version` | string | `ouo-node-identity/1` |
| `object_version` | integer | `1` |
| `node_id` | string | self-certifying NodeID |
| `root_public_key` | base64url | Ed25519 root public key |
| `operational_public_key` | base64url | Ed25519 operational public key |
| `serial` | UUID string | уникальный serial сертификата |
| `issued_at` | UTC timestamp | начало действия |
| `valid_until` | UTC timestamp | окончание действия |
| `signature_algorithm` | string | `Ed25519` |
| `signature` | base64url | подпись Node Root |

Максимальный срок сертификата v1 — 7 суток. Более длинный сертификат
отклоняется, даже если подпись корректна.

## Signature scope

Из объекта удаляется только поле `signature`. Остальные поля кодируются как
canonical JSON: UTF-8, ключи отсортированы, без незначащих пробелов. Подпись:

```text
Ed25519.sign(
  NodeRootPrivateKey,
  "OUO/NODE_OPERATIONAL_CERT/v1\0" || canonical_json(certificate_without_signature)
)
```

Domain separation обязателен. Этот ключ/контекст нельзя использовать для
пользовательских сообщений, route objects или update metadata.

## Validation order
1. Ограничить размер входного объекта на transport/API слое.
2. Проверить точный набор полей и версии.
3. Декодировать ключи и проверить их длину.
4. Пересчитать `node_id` из `root_public_key`.
5. Проверить UTC timestamps, срок не более 7 суток и допустимый clock skew.
6. Проверить root signature.
7. Для legacy registration сравнить `issued_at` с persistent highest accepted
   Operational Certificate. Для distributed live admission проверить точный
   root-signed `credential_epoch`/hash-chain head по `0237`; wall-clock arrival
   order не является authority.
8. Проверить quorum revocation state по точным `(node_id, serial, key,
   certificate_hash)` и event time согласно `0238`.

Любая ошибка означает `REJECT` (fail closed).

## Rotation и revocation
- Operational rotation: новый key + новый serial + новый root-signed cert;
  NodeID не меняется.
- Operational compromise: serial отзывается, выпускается новый сертификат.
- Node Root compromise: требуется quorum-signed revocation и identity
  transition; автоматическая тихая замена NodeID запрещена.
- Старый operational key после expiry/revocation не принимается для heartbeat,
  federation или NodeAdvertisement.
- Discovery enforce-registration хранит highest accepted certificate и не
  позволяет ещё не истёкшему старому сертификату откатить operational key.
- D1/D2/D3 реплицируют root-signed monotonic credential chain; historical
  evidence проверяется на время события отдельно от live high-watermark.
- D1/D2/D3 отдельно реплицируют quorum-signed serial revocation; она не меняет
  Level/Capability и не заменяет node-wide TrustRecord revocation.

## Миграция LIVE
Текущий `NODE_ID=home-a` является legacy alias. Интеграция выполняется без
резкого переключения:

1. Discovery начинает хранить `legacy_node_id`, self-certifying `node_id` и
   OperationalCertificate.
2. В report mode проверяет сертификат, не блокируя старые ноды.
3. После миграции всех тестовых нод signed mode требует сертификат.
4. Capabilities принимаются только из отдельного CapabilityCertificate, а не
   из самодекларации регистрации.

## Не входит в этот шаг
- CapabilityCertificate и validator quorum.
- Node Root transition/recovery ledger.
- TPM/TEE attestation.
- Quorum-signed Node Root transition/recovery.

## Reference implementation
- `shared/security/node_identity.py`
- `shared/security/node_identity_credentials.py`
- `shared/security/node_identity_enrollment.py`
- `shared/security/operational_credential_state.py`
- `shared/security/operational_credential_revocation.py`
- `spec/0239_NODE_ROOT_COMPROMISE_BOUNDARY.md`
- `tests/security/test_node_identity.py`
- `tests/security/test_node_identity_enrollment.py`
- `tests/integration/test_discovery_node_identity.py`
