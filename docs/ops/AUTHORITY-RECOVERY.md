# OUO Authority Recovery — операторский runbook

Это аварийная процедура. Она не используется для обычной ротации L5 и не
заменяет AuthorityCheckpoint.

## Preconditions

- имеется подтверждённая компрометация/loss normal authority quorum;
- D1/D2/D3 находятся в `control_plane_frozen`;
- data plane по возможности продолжает existing sessions/routes;
- public recovery state одинаково provisioned на каждой Discovery;
- offline recovery private keys не копируются на сервер и не передаются по API;
- выбран новый независимый authority set и epoch выше highest observed epoch.

Если control plane не frozen, endpoint обязан вернуть `409`.

## Offline ceremony

На изолированных устройствах:

1. собрать текущие checkpoint hashes и highest epochs со всех Discovery;
2. зафиксировать incident/reason и covered compromised epoch;
3. создать replacement checkpoint с новым committee, threshold и credentials;
4. получить требуемый threshold offline signatures (например 3-of-5);
5. сверить canonical recovery hash минимум двумя операторами;
6. перенести только публичный подписанный `AuthorityRecovery` object.

Никаких recovery private keys на production host.

## Apply на каждой Discovery

Проверить до отправки:

```sh
curl -fsS https://DISCOVERY_OVERLAY_IP/health
```

Затем отправить один и тот же recovery JSON через закрытый admin overlay:

```sh
curl -fsS \
  -H "X-Discovery-Admin-Secret: ${DISCOVERY_ADMIN_SECRET}" \
  -H "X-Operator-Id: offline-recovery-ceremony" \
  -H "Content-Type: application/json" \
  --data-binary @authority-recovery-request.json \
  https://DISCOVERY_OVERLAY_IP/admin/authority/recovery
```

`authority-recovery-request.json` содержит только:

```json
{"recovery": {}}
```

где значение `recovery` — полностью подписанный protocol object.

Для D1/D2/D3 должны совпасть:

- `recovery_hash`;
- `replacement_checkpoint_hash`;
- `authority_epoch`;
- `governance_allowed=true`.

## Post-recovery verification

1. Получить `/registry/authority-checkpoints/latest` на каждой Discovery.
2. Проверить одинаковый replacement hash/epoch.
3. Выпустить новые CapabilityCertificates уже новым authority quorum.
4. Выполнить следующий normal AuthorityCheckpoint, чей `previous_hash` равен
   replacement hash.
5. Проверить 4-of-7 rejection и 5-of-7 acceptance.
6. Проверить, что старые normal/recovery objects не дают rollback.
7. Сохранить audit log и artifact hashes; не сохранять private keys.

## Fail closed

Остановить ceremony и оставить Safe Mode, если:

- D1/D2/D3 показывают необъяснимо разные highest epochs;
- offline signatures/committee расходятся;
- replacement hash различается;
- хотя бы одна Discovery принимает объект без threshold;
- новый authority set не прошёл независимую проверку.

Автоматического rollback recovery нет. Исправление ошибочного, но уже принятого
recovery требует нового, более высокого emergency epoch и новой offline
ceremony.
