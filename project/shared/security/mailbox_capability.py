"""Opaque 256-bit mailbox capabilities for Storage v1."""

import base64
import hashlib
import hmac
import os


DOMAIN = b"OUO/MAILBOX_CAPABILITY/v1\x00"


def _encode(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")


def mailbox_token_bytes(token: str) -> bytes:
    if not isinstance(token, str) or len(token) != 43:
        raise ValueError("mailbox token must encode 32 bytes")
    try:
        raw = base64.b64decode(
            (token + "=").encode("ascii"), altchars=b"-_", validate=True
        )
    except (UnicodeEncodeError, ValueError) as exc:
        raise ValueError("invalid mailbox token") from exc
    if len(raw) != 32 or not hmac.compare_digest(_encode(raw), token):
        raise ValueError("invalid mailbox token")
    return raw


def generate_mailbox_token() -> str:
    return _encode(os.urandom(32))


def derive_mailbox_token(*, secret: bytes, mailbox_scope: str, epoch: int) -> str:
    if not isinstance(secret, bytes) or len(secret) < 32:
        raise ValueError("mailbox secret must contain at least 32 bytes")
    if not isinstance(mailbox_scope, str) or not 1 <= len(mailbox_scope) <= 256:
        raise ValueError("mailbox_scope is invalid")
    if not isinstance(epoch, int) or isinstance(epoch, bool) or epoch < 0:
        raise ValueError("mailbox epoch must be a non-negative integer")
    payload = DOMAIN + str(epoch).encode("ascii") + b"\x00" + mailbox_scope.encode("utf-8")
    return _encode(hmac.new(secret, payload, hashlib.sha256).digest())
