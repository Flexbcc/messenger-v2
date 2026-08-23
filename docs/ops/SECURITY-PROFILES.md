# OUO node security profiles

## Migration profile

Базовый `docker-compose.yml` сохраняет `legacy/report/off` switches для
пошагового переноса существующего стенда. Он не является production-secure и
не должен публиковаться наружу.

## Enforce profile

`docker-compose.secure.yml` — отдельный fail-closed override. Он требует:

- strict enrollment и self-certifying NodeID;
- Operational Credential chain/revocation;
- Capability Certificate и локальный Authority State;
- Trust Ledger и quorum randomness;
- gossip минимум между тремя Discovery;
- signed peer selection и RouteDescriptor quorum;
- signed federation envelope/admission;
- независимые application/TURN/admin secrets.

`scripts/validate-secure-env.py` должен завершиться без ошибок до построения
compose-конфигурации. Пустой quorum, отсутствующий trust file или `report`
mode считаются ошибкой, а не причиной автоматически ослабить профиль.
