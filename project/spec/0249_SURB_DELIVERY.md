# 0249 — SURB Delivery v1

Sender не должен добавлять реальную Home получателя в собственноручно
построенный маршрут. Получатель заранее создаёт Single Use Reply Blocks (SURB),
которые содержат скрытый обратный маршрут до destination Home/ingress, и
передаёт их контакту внутри существующего E2EE relationship.

Sender вызывает provider `build_reply(surb, final_mailbox_dispatch)` и узнаёт
только первый ingress NodeID и готовый fixed-size packet. SURB одноразовый:
локальный persistent store атомарно помечает его consumed и очищает blob. TTL и
hard record limit ограничены. Повторное использование запрещено.

Discovery не хранит SURB established contacts. При исчерпании blocks endpoint
запрашивает новые внутри E2EE; bootstrap/recovery использует отдельный
ограниченный rendezvous mechanism.
