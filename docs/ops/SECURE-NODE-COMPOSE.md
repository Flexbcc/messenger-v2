# Secure compose baseline для нод

## Статус
Подготовлен и проверяется статически. Контейнеры этим документом не запускаются.

## Файлы
- `project/docker-compose.yml` — базовые сервисы;
- `project/docker-compose.secure.yml` — security override;
- `project/.env.secure.example` — только шаблон, без рабочих секретов;
- `project/scripts/validate-secure-env.py` — fail-closed preflight.

## Что включает override
- strict enrollment;
- signed service-to-service federation;
- signed FederationEnvelope;
- strict one-time PreKey consumption;
- Node Identity, NodeAdvertisement, Capability Certificate и federation
  capability authorization работают в enforce. До provision public Authority
  State и role-specific certificates secure profile намеренно не готов к запуску;
- Home использует persistent binary WebSocket к Relay с HTTP fallback;
- Home поддерживает bounded Storage replica set (`1..5`), write quorum и
  deduplicated drain; baseline Compose оставляет `1-of-1`, пока не созданы
  независимые Storage nodes;
- Relay ограничивает global/per-peer WSS connections, frame/cells, idle,
  cell-processing и send timeouts; значения заданы в `.env.secure.example`;
- обязательные независимые secrets;
- Gateway TLS + required client certificate;
- внутренние Storage/Relay остаются без host port publication.
- AuthorityCheckpoint pull-gossip присутствует, но по умолчанию выключен;
  включается только после provision взаимно зарегистрированных Discovery с
  действующими certified `discovery` capabilities.
- signed-mode mesh bootstrap требует независимый `MESH_NOTIFY_SECRET`; пустое
  значение останавливает создание mesh router fail closed.

HTTP endpoints базового compose имеют отдельные `*_BIND`. До настройки
Tailscale/WireGuard в secure env используется `127.0.0.1`. Панель Proxmox к
этому compose отношения не имеет и наружу не публикуется.

## Подготовка (не выполнять с example secrets)

```bash
cd project
cp .env.secure.example .env.secure
chmod 600 .env.secure
# заменить каждый REPLACE... независимым CSPRNG secret
python3 scripts/validate-secure-env.py .env.secure
docker compose --env-file .env.secure \
  -f docker-compose.yml -f docker-compose.secure.yml config
```

Только после успешного preflight и отдельного подтверждения оператора допустим
`docker compose up` на целевом стенде.

## Не закрыто
- mTLS certificates должны быть сгенерированы и распределены;
- Capability Authority State ещё не создан;
- `AUTHORITY_GOSSIP_PEERS` должен содержать только origin адреса D1/D2/D3 в
  Tailscale/WireGuard overlay; redirects, URL credentials и произвольные
  runtime targets не принимаются;
- `NODE_ADVERTISEMENT_GOSSIP_PEERS` задаётся отдельно в том же origin-формате.
  `NODE_ADVERTISEMENT_GOSSIP_ENABLED=true` включается после взаимной
  регистрации D1/D2/D3 с действующими quorum `discovery` certificates;
- `TRUST_RECORD_GOSSIP_PEERS` также содержит два других Discovery origin для
  каждой D1/D2/D3. Полученные решения повторно проверяются по quorum и
  historical Authority epoch; HTTP peer не считается источником доверия.
  `TRUST_RECORD_GOSSIP_ENABLED=true` включается только после provision TLS и
  независимых Discovery failure domains;
- `TRUST_LEDGER_MODE=enforce` не проходит preflight без
  `TRUST_AUTHORITY_STATE_PATH`, `TRUST_RECORD_GOSSIP_ENABLED=true` и
  `AUTHORITY_GOSSIP_ENABLED=true`; оба peer list обязаны содержать минимум два
  корректных origin;
- `CHALLENGE_ASSIGNMENT_GOSSIP_PEERS` задаётся по той же D1/D2/D3 схеме.
  Этот же bounded peer set переносит quorum RandomnessCheckpoint раньше
  assignment. После его сходимости `RANDOMNESS_CHECKPOINT_MODE` переключается
  `report → enforce`; enforce повторно вычисляет observer set;
  Реплика повторно проверяет historical Authority/quorum; подписанные ACK
  передаются отдельным append-only pull тем же peer set и независимо
  перепроверяются. Assignment-bound TrustObservation/completion также
  передаётся отдельным append-only pull и применяется только после ACK;
- тот же D1/D2/D3 peer set реплицирует root-signed Operational Credential
  chain. `OPERATIONAL_CREDENTIAL_STATE_MODE` оставляется `report`, пока каждая
  node runtime не публикует полный непрерывный chain. Для opt-in задаётся
  `NODE_OPERATIONAL_CREDENTIAL_CHAIN_PATH`; существующий certificate без chain
  намеренно не получает тихий epoch-0 reset. После миграции portable observer
  и registration/heartbeat renewal можно переключить в `enforce`;
- `OPERATIONAL_CREDENTIAL_REVOCATION_MODE` переключается `report → enforce`
  только после включения credential-state enforce, provision исторического
  `TRUST_AUTHORITY_STATE_PATH` и подтверждения сходимости D1/D2/D3. Отзыв
  одного serial не заменяет node-wide TrustRecord revocation или Root recovery;
- Home `SIGNED_PEER_SELECTION_MODE=enforce` требует минимум два адреса в
  `PEER_DISCOVERY_URLS`, актуальные `PEER_AUTHORITY_STATE_PATH` и
  `PEER_DISCOVERY_SOURCE_SET_PATH`. Source-set содержит только public
  Operational/Capability certificates; локальный `PEER_SELECTION_SEED_PATH`
  является приватным и не копируется между Home Nodes;
- `TRUST_DEGRADATION_MODE=observe` обязателен в secure profile: локальный
  heartbeat outage является reliability evidence, но не quorum decision;
- `FEDERATION_NODE_ID_MODE=enforce` переводит data-plane подписи с operator
  alias на self-certifying NodeID из Operational Certificate; отсутствие
  identity paths приводит к fail-closed startup/request failure;
- `RECOVERY_AUTHORITY_STATE_PATH` содержит только public offline recovery
  credentials; private recovery keys запрещены на production нодах;
- для `CAPABILITY_CERTIFICATE_MODE=enforce` каждому infrastructure node нужен
  отдельный `/data/capability_certificate.json`, а federation policy можно
  запускать только после их проверки. Home L0 не требует infrastructure
  certificate, пока не заявляет такую роль;
- `STORAGE_NODE_URLS` содержит только origin адреса Storage в overlay;
  `STORAGE_WRITE_QUORUM` не может превышать `STORAGE_REPLICATION_FACTOR`;
  несколько контейнеров на одном физическом хосте не считаются независимыми
  failure domains;
- адрес bind должен быть заменён на конкретный overlay IP после аудита;
- production secrets должны поступать из secret manager/files, а не Git.
