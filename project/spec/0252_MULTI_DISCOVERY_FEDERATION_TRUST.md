# 0252 — Multi-Discovery Federation Trust Cache v1

В secure profile входная Federation authentication не получает Operational
public key и capabilities из одного `/registry/nodes`.

Каждый сервис опрашивает `FEDERATION_DISCOVERY_URLS` и принимает peer только
если минимум `FEDERATION_MINIMUM_DISCOVERY_SOURCES` возвращают одинаковый
security commitment peer-view. Commitment включает NodeID, endpoint,
Operational Certificate, advertisement/capability epochs и deadlines,
capabilities, quotas и Transport Certificate. Observer lists могут различаться.

После quorum сервис локально проверяет root signature и срок Operational
Certificate, связывает `NodeID = hash(NodeRootPublicKey)` и использует только
его `operational_public_key` для Federation request signature. Capability и
quota берутся из кворумного conservative view. Конфликтующие quorum variants,
недостаток источников и malformed candidate исключают peer fail closed.

Cache bounded временем `TRUST_CACHE_TTL_SECONDS`; пустой quorum view является
валидным negative cache и не вызывает запрос на каждый неизвестный NodeID.
Каждая positive entry дополнительно истекает по минимуму Advertisement,
Operational, Capability и Transport deadlines, даже если общий refresh TTL ещё
не закончился.
Legacy single-Discovery path остаётся только когда
`FEDERATION_DISCOVERY_URLS` не задан, и не допускается валидатором secure env.

Ограничение: независимость URL не доказывает независимость операторов. D1/D2/D3
должны иметь разные Node Identity, ключи, state и желательно operator/network.
