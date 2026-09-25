# Shared contracts (MVP)

Единый источник правды для форматов, которые должны совпадать между всеми
сервисами и клиентом. Конкретные сервисы (Python) реализуют эти формы как
свои Pydantic-модели; клиент (Dart/Flutter) — как классы/интерфейсы. Смысл
в том, чтобы при рассинхронизации был один документ для сверки, а не N
реализаций, придуманных параллельно.

См. также [ADR-0004](../spec/ADR/0004-mvp-staged-implementation.md) и
[ADR-0005](../spec/ADR/0005-reuse-legacy-projects-and-real-crypto.md).

## Message Envelope (JSON, MVP-транспорт)

Временная JSON-сериализация вместо целевого бинарного формата из
[0201_PACKETS.md](../spec/0201_PACKETS.md) — поля названы так же, чтобы
переход на бинарный Packet не потребовал переосмысления модели, только
сериализации.

```json
{
  "packet_id": "uuid",
  "type": "MESSAGE | ACK | HANDSHAKE",
  "conversation_id": "uuid",
  "sender_user_id": "uuid",
  "sender_device_id": "uuid",
  "crypto_version": "signal-v1",
  "ciphertext": "base64",
  "content_type": "text | image | file | voice",
  "created_at": "2026-07-05T12:00:00Z"
}
```

- `crypto_version` — версия Crypto Provider, которым зашифрован `ciphertext` (см. ADR-0004). Позволяет получателю выбрать нужный Crypto Provider при расшифровке и эволюционировать схему без ломающих изменений.
- `ciphertext` для сервера — непрозрачный blob. Ни один сервис не пытается его разобрать.

## Identity / Device / Auth

Аутентификация устройства (целевая модель) — challenge-response на
Ed25519-ключе устройства (Zero Trust, см. [0300_CRYPTO.md](../spec/0300_CRYPTO.md)).
Это отдельный ключ от Signal identity key внутри `libsignal_protocol_dart`.

**LIVE (`mvp-json`, R2):** primary onboarding — password register/login
([ADR-0007](../spec/ADR/0007-password-identifier-login-bridge.md));
`/auth/challenge` + `/auth/verify` используются для обновления JWT.
Полный mapping handshake ↔ REST/WS: [0200_PROTOCOL.md](../spec/0200_PROTOCOL.md),
reality [`docs/reality/R2-wire-today.md`](../../docs/reality/R2-wire-today.md).

```
POST /auth/register | /auth/login   (password bridge + auth_public_key + bundle)
  -> { user_id, device_id, access_token }

POST /auth/challenge
  { device_id }
  -> { nonce, expires_at }

POST /auth/verify
  { device_id, nonce, signature }
  -> { access_token (JWT), user_id, device_id }

WS /ws?token=<jwt>   (push new_message; не Packet-multiplex send)
```

## Crypto API (контракт клиента, реализация — `libsignal_protocol_dart`)

```dart
abstract class CryptoProvider {
  Future<IdentityKeyPair> generateIdentity();
  Future<DeviceKeys> generateDevice(IdentityKeyPair identity);
  Future<PreKeyBundle> generatePreKeyBundle(DeviceKeys device);

  Future<Envelope> encryptForConversation(String conversationId, List<int> plaintext);
  Future<List<int>> decryptEnvelope(Envelope envelope);

  Future<void> rotateKeys();
  bool verifySignature(List<int> message, List<int> signature, List<int> publicKey);
}
```

Ни Client UI, ни Home Node, ни один другой Node не вызывают
криптографическую библиотеку напрямую — только через этот интерфейс
(Zero Trust, Security by Design).
