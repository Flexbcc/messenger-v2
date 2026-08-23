# 0241 — Opaque Ingress Envelope v1

Ingress API принимает только объект `ouo-opaque-ingress/1`:

- `packet_format = sphinx-provider/1`;
- fixed-size binary packet 4/16/64/256 KiB в base64url;
- expiry не более пяти минут.

В outer object запрещены UserID, DeviceID, conversation ID, endpoint message
ID, Home URL и открытый route. Identity предыдущей ноды известна только link
admission и не вкладывается в следующий hop.

Криптографическая onion-конструкция не реализуется внутри OUO произвольной
композицией primitives. `OnionPacketProvider` задаёт минимальную границу
`build/unwrap`, hop public keys, per-hop replay tag и ровно одно из
`next_packet`/`final_payload`. Без подключённого рассмотренного Sphinx provider
runtime обязан fail closed.
