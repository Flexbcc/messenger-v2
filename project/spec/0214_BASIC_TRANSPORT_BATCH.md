# 0214 — Basic Transport binary batch v1

## Назначение

Это transport-agnostic framing для persistent WSS и будущего QUIC adapter.
Он не является Mix/Sphinx и не меняет FederationEnvelope.

## Wire format

Big-endian header:

```text
magic[4] = OUOB
version:u8 = 1
flags:u8 = 0
reserved:u16 = 0
batch_sequence:u64
cell_count:u16
repeated cell_count:
  cell_length:u32
  cell_bytes[cell_length]
```

V1 ограничивает batch 1 MiB, 256 cells и одну cell 256 KiB. Пустые cells,
unknown flags/version, trailing bytes, truncation и over-limit length
отклоняются до дальнейшего parsing.

`LinkSequenceStore` хранит highest accepted sequence по `(peer_node_id,
connection_id)` в SQLite. Повтор и reorder на link layer отклоняются даже после
restart. Connection ID должен быть аутентифицирован HELLO handshake; глобальный
packet ID самим link framing не вводится. Legacy Basic Relay payload пока ещё
содержит endpoint packet metadata; её сокрытие относится к onion layer.

Первая sequence соединения обязана быть `1`, каждая следующая — строго
предыдущая `+1`. Обновление выполняется в `BEGIN IMMEDIATE`, поэтому два
параллельных frame одного connection ID не могут пройти одну проверку. Состояние
имеет TTL и общий лимит записей; сначала удаляются истёкшие, затем самые старые.

## Реализованный adapter

Relay выполняет signed federation admission, Capability check, connection limit
и принимает только binary batches. Runtime дополнительно ограничивает:

- глобальные и per-peer WebSocket connections;
- idle lifetime соединения;
- cells в одном batch (deployment default 32, wire maximum 256);
- время обработки одной cell и время отправки ответа;
- WebSocket frame на уровне uvicorn (deployment default 1 MiB).

Глобальные deployment limits являются верхней границей. Если у peer есть
валидный Capability Certificate, `max_connections` и `max_cells_per_epoch`
дополнительно сужают фактический budget. Нулевой сертифицированный quota
означает запрет соответствующей операции.

В `RELAY_TARGET_VALIDATION_MODE=enforce` Relay направляет трафик только на Home,
у которой одновременно действительны Node Identity, NodeAdvertisement и
Capability Certificate `home`, а target URL присутствует в подписанном списке
advertised endpoints. Legacy `node_url` без этих связей недостаточен.

Connection budget резервируется до первой await/auth операции, поэтому
параллельные handshakes не обходят глобальный лимит. Обработка внутри одного
соединения последовательна: server-side unbounded queue не создаётся.

Home поддерживает одну persistent session на Relay, ordered sequence, reconnect
с новым connection nonce и режимы:

- `http`;
- `websocket-preferred` с HTTP fallback;
- `websocket-required`.

Secure compose использует `websocket-preferred`. Cell payload пока содержит
Basic Relay envelope; fixed-size cell реализована отдельно, но её включение в
data plane, onion layer и QUIC остаются следующими этапами.
## Transport Adapter

Верхний Basic Relay protocol не зависит от конкретного link transport.
`RelayTransportAdapter` предоставляет одинаковые `forward`/`forward_many` для
HTTP и persistent WSS. В режиме `websocket-preferred` WSS используется первым,
а подписанный HTTP остаётся совместимым fallback; `websocket-required`
fail-closed переходит к следующей Relay без downgrade на HTTP.

Одна WSS-сессия переиспользуется для Relay origin, batch сохраняет порядок
cells, а ответ обязан иметь тот же sequence и то же количество cells.
Reconnect создаёт новую подписанную connection nonce и начинает независимую
link sequence.

Каждая WSS cell дополнительно имеет свежий per-hop `cell_id`, короткое окно
`created_at`/`expires_at` и вложенный protocol payload. Relay принимает этот ID
ровно один раз через bounded nonce store. Идентификатор существует только на
данном link и не переиспользуется следующим hop.

Relay также потребляет отдельный replay tag из собственного NodeID и nonce
подписанного FederationEnvelope. Поэтому повтор одного envelope на той же Relay
не создаёт amplification, а следующий независимый hop имеет другое replay
пространство.
