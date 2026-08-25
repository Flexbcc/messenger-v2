# 0257 — QUIC Transport Adapter v1

QUIC является сменным link adapter и не меняет OUO relay payload, federation
signature или E2EE. Первая реализация использует HTTP/3 из `aioquic 1.3.0`:

```text
RelayTransportAdapter
  ├─ HTTP compatibility
  ├─ persistent binary WSS
  └─ persistent QUIC + independent HTTP/3 streams
```

Home поддерживает режимы `quic-preferred` и `quic-required`. Preferred при
ошибке QUIC использует подписанный HTTPS fallback; required fail closed. Один
QUIC connection переиспользуется для origin, а элементы batch отправляются в
независимых streams, поэтому потеря одного stream не создаёт TCP head-of-line
blocking для остальных.

## Security boundary

- только `https://` endpoint;
- TLS certificate validation всегда `CERT_REQUIRED`;
- system CA либо отдельный `RELAY_QUIC_CA_FILE`;
- 0-RTT не используется, чтобы replayable early data не переносила forward;
- каждый POST всё равно содержит обычную OUO federation signature, timestamp и
  nonce; TLS не заменяет Node Identity/Capability admission;
- response ограничен 1 MiB и обязан быть JSON object;
- reconnect создаёт новый QUIC connection, один неуспешный link удаляется из
  pool перед retry.

Relay запускает тот же FastAPI application через Hypercorn. TCP/TLS и QUIC/UDP
слушают одинаковый номер порта, поэтому один signed endpoint работает для
HTTP, WSS и HTTP/3. QUIC включается только явно:

```text
RELAY_QUIC_ENABLED=true
RELAY_TLS_CERT_FILE=/run/secrets/relay.crt
RELAY_TLS_KEY_FILE=/run/secrets/relay.key
```

Порт должен быть опубликован одновременно как TCP и UDP. Сертификат и ключ не
встраиваются в image и не передаются через Discovery. Discovery публикует
endpoint/transport support, но клиент самостоятельно проверяет TLS и signed
node records.
