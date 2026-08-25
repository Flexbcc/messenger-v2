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

## Client delivery contract

Клиент передаёт созданные reply blocks как control envelope с
`content_type=ouo_surb_bundle`. JSON `ouo-surb-bundle/1` сначала шифруется
существующей pairwise E2EE-сессией отдельно для каждого DeviceID, и только
получившиеся `device_envelopes` отправляются через Home. Поэтому Home, Relay и
Discovery не получают SURB blob или скрытый route.

Получатель:

1. расшифровывает envelope своей DeviceKey/ratchet session;
2. проверяет protocol version, TTL, размер и
   `SHA256("OUO/SURB_ID/v1\\0" || surb)`;
3. сохраняет blocks в локальное device-encrypted хранилище по peer UserID;
4. атомарно удаляет выбранный block до передачи transport adapter.

Control envelope не отображается в переписке и не создаёт notification.
Повторная доставка одного `surb_id` идемпотентна. Один bundle содержит не более
16 blocks; локальный запас ограничен 128 blocks на peer; максимальный TTL — 30
дней.

Создание криптографического SURB остаётся обязанностью endpoint transport
provider. Серверный Rust sidecar может использоваться локальным desktop-node
endpoint либо будущим native client adapter, но Home API не принимает открытый
route или SURB от клиента: добавление такого API нарушило бы trust boundary.
