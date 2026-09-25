"""Authenticated at-rest encryption for third-party push device tokens."""

from __future__ import annotations

import base64
import binascii
import hashlib

from nacl.exceptions import CryptoError
from nacl.secret import SecretBox
from nacl.utils import random as random_bytes

from app.config import settings

_PREFIX = "v1:"
_MAX_CLEAR_BYTES = 16 * 1024
_KEY_CONTEXT = b"ouo-push-token-at-rest-v1"


class TokenDecryptionError(ValueError):
    """Stored token is legacy plaintext, malformed, or encrypted under another key."""


def _box() -> SecretBox:
    key = hashlib.blake2b(
        settings.token_encryption_secret.encode("utf-8"),
        digest_size=SecretBox.KEY_SIZE,
        person=_KEY_CONTEXT[:16],
    ).digest()
    return SecretBox(key)


def encrypt_push_token(token: str) -> str:
    if not isinstance(token, str):
        raise TypeError("push token must be text")
    clear = token.encode("utf-8")
    if not 1 <= len(clear) <= _MAX_CLEAR_BYTES:
        raise ValueError("push token size is invalid")
    encrypted = _box().encrypt(clear, random_bytes(SecretBox.NONCE_SIZE))
    return _PREFIX + base64.urlsafe_b64encode(bytes(encrypted)).decode("ascii")


def decrypt_push_token(stored: str) -> str:
    if not isinstance(stored, str) or not stored.startswith(_PREFIX):
        raise TokenDecryptionError("push token is not encrypted")
    encoded = stored.removeprefix(_PREFIX)
    if not encoded or len(encoded) > 24 * 1024:
        raise TokenDecryptionError("encrypted push token size is invalid")
    try:
        packed = base64.b64decode(encoded, altchars=b"-_", validate=True)
        if base64.urlsafe_b64encode(packed).decode("ascii") != encoded:
            raise TokenDecryptionError("encrypted push token is not canonical")
        clear = _box().decrypt(packed)
        token = clear.decode("utf-8")
    except (ValueError, UnicodeDecodeError, binascii.Error, CryptoError) as exc:
        raise TokenDecryptionError("encrypted push token is invalid") from exc
    if not 1 <= len(clear) <= _MAX_CLEAR_BYTES:
        raise TokenDecryptionError("decrypted push token size is invalid")
    return token
