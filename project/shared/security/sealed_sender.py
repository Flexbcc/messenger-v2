"""Sealed Sender для federation (Task #68).

Скрывает sender_user_id от промежуточных нод (relay, hub) при доставке сообщений.
Принимающий Home-node — единственный кто может расшифровать реального отправителя.

Механизм:
  - Отправляющий Home-node знает receiver Home-node public key (из Discovery)
  - sender_user_id шифруется NaCl Box (ephemeral X25519 ECDH)
  - В envelope идёт `sealed_sender_box` вместо открытого `sender_user_id`
  - Relay nodes видят только `sealed_sender_box` — опак блоб
  - Принимающий Home-node расшифровывает используя свой private key

Это базовая реализация без receiver certificate (как в Signal).
Полноценный sealed sender требует отдельного механизма sender certificate.
"""
from __future__ import annotations

import base64
from typing import Optional

from nacl.exceptions import CryptoError
from nacl.public import PrivateKey, PublicKey, SealedBox

from shared.security.transport_credentials import load_or_create_transport_key

_PUBLIC_KEY_BYTES = PublicKey.SIZE
_MAX_SENDER_ID_BYTES = 512
_MAX_SEALED_BOX_BYTES = _MAX_SENDER_ID_BYTES + PublicKey.SIZE + 16


def _decode_b64(value: str, *, maximum: int) -> bytes:
    if not isinstance(value, str) or not value or len(value) > maximum * 2:
        raise ValueError("invalid sealed-sender base64 value")
    raw = base64.b64decode(value, altchars=b"-_", validate=True)
    if not raw or len(raw) > maximum:
        raise ValueError("invalid sealed-sender payload size")
    return raw


def _load_or_create_curve_key(path: str) -> PrivateKey:
    """Load or create X25519 key for sealed sender encryption."""
    return load_or_create_transport_key(path)


# Per-process cache (loaded once per startup)
_curve_key: Optional[PrivateKey] = None
_curve_key_path: Optional[str] = None


def get_or_create_curve_key(path: str) -> PrivateKey:
    global _curve_key, _curve_key_path
    if _curve_key is None or _curve_key_path != path:
        _curve_key = _load_or_create_curve_key(path)
        _curve_key_path = path
    return _curve_key


def curve_public_key_b64(private_key: PrivateKey) -> str:
    return base64.urlsafe_b64encode(bytes(private_key.public_key)).decode()


def seal_sender(
    sender_user_id: str,
    receiver_public_key_b64: str,
) -> str:
    """Зашифровать sender_user_id для конкретного receiver Home-node.

    Использует SealedBox (anonymous sender ECIES) — никаких метаданных об
    отправителе не утекает в зашифрованный блоб.

    Returns base64-encoded sealed box.
    """
    sender_bytes = sender_user_id.encode("utf-8")
    if not sender_bytes or len(sender_bytes) > _MAX_SENDER_ID_BYTES:
        raise ValueError("sender_user_id has an invalid size")
    receiver_key = _decode_b64(
        receiver_public_key_b64,
        maximum=_PUBLIC_KEY_BYTES,
    )
    if len(receiver_key) != _PUBLIC_KEY_BYTES:
        raise ValueError("receiver public key must contain exactly 32 bytes")
    receiver_pk = PublicKey(receiver_key)
    box = SealedBox(receiver_pk)
    ciphertext = box.encrypt(sender_bytes)
    return base64.urlsafe_b64encode(ciphertext).decode()


def unseal_sender(
    sealed_box_b64: str,
    receiver_private_key: PrivateKey,
) -> Optional[str]:
    """Расшифровать sender_user_id. Возвращает None при ошибке."""
    try:
        box = SealedBox(receiver_private_key)
        raw = _decode_b64(sealed_box_b64, maximum=_MAX_SEALED_BOX_BYTES)
        plaintext = box.decrypt(raw)
        if not plaintext or len(plaintext) > _MAX_SENDER_ID_BYTES:
            return None
        sender_user_id = plaintext.decode("utf-8")
        if not sender_user_id:
            return None
        return sender_user_id
    except (CryptoError, ValueError, TypeError, UnicodeDecodeError):
        return None
