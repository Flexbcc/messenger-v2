# 0247 — Mix Ingress Runtime v1

Relay принимает только `OpaqueIngressPacket`, передаёт fixed-size packet в
injected Sphinx provider и проверяет per-hop replay tag через persistent bounded
store. Provider обязан вернуть ровно один результат:

- `next_node_id + next_packet`; либо
- `final_payload`.

Результат помещается в bounded Mix Pool и отправляется после jitter. Следующий
packet снова обязан иметь фиксированный размер. Replay store сохраняет только
domain-separated SHA-256 tag, имеет TTL и hard record limit.

Запись Mix Pool наследует оставшийся срок входного envelope и не может жить
дольше него. При переполнении pool replay reservation откатывается, поскольку
пакет не был принят; для принятого пакета tag сохраняется до TTL. Replay-cache
никогда не удаляет ещё действующие tags ради новых: при полном окне admission
завершается fail closed.

Исходный ingress `expires_at` переносится через внутреннюю очередь и следующий
hop без изменений. Relay не выдаёт пакету новое окно `now + TTL`, поэтому
multi-hop forwarding не продлевает lifetime на каждом переходе.
Сам expiry входит в authenticated onion data и возвращается provider при
unwrap. Его точное несовпадение с внешним envelope отклоняется до записи replay
tag, поэтому malicious previous hop не может увеличить lifetime новой подписью.

Runtime не знает UserID, conversation ID, полный маршрут или Home пользователя.
Без reviewed provider `UnavailableOnionProvider` прекращает admission ошибкой.

Relay-only runtime отклоняет `final_payload`: завершать маршрут может только
destination ingress/Home role с отдельным final-delivery handler. Это не даёт
обычной Relay случайно превратиться в endpoint или интерпретировать payload.

Relay разрешает следующий NodeID не через один registry. Он получает peer-view
из настроенного набора независимых Discovery, сравнивает security commitment
(endpoint, advertisement/capability epochs, capabilities и Transport
Certificate), требует quorum одинаковых вариантов и ещё раз локально проверяет
certificate. Observer lists могут различаться и не входят в commitment. Два
разных варианта, достигших quorum, неоднозначность или self-loop дают fail closed.
Allowlist resolver содержит только `relay|home`: промежуточный hop использует
Relay, а последний переход может адресовать destination Home. Storage,
Discovery и остальные capabilities не становятся Mix hop автоматически.
Ожидаемая роль следующего hop входит в authenticated onion layer. Relay требует
quorum candidate именно с этой capability; наличие у NodeID другой допустимой
роли не удовлетворяет маршруту.

Успешное quorum resolution помещается в короткоживущий bounded cache NodeID ->
endpoint. Single-flight lock не позволяет параллельному batch создать шторм
одинаковых Discovery lookup. Cache не содержит UserID/full route и не продлевает
запись при Discovery outage; expiry cache равен минимуму настроенного TTL и
deadlines NodeAdvertisement, Operational Certificate, Capability Certificate и
Transport Certificate. После него требуется новый quorum.
