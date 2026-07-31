"""
User Record signing for Discovery Node.

Every user→home mapping returned by Discovery is signed with Discovery's
Ed25519 key so that home-nodes can verify the record's authenticity before
using it for routing. This closes the "подписанных user Discovery-записей
в LIVE нет" gap from 0203_ROUTING.md / R4-routing.md.

Signed payload (canonical, |-separated, UTF-8):
    user_id | home_node_url | updated_at

Signature is Ed25519 over the UTF-8 bytes of that string, base64url-encoded.
The Discovery public key is included in every response so that home-nodes
that don't yet have a cached copy can still verify immediately.
"""
from __future__ import annotations

import base64
from functools import lru_cache

from nacl.signing import SigningKey, VerifyKey
from nacl.exceptions import BadSignatureError

from app.config import DISCOVERY_SIGNING_KEY_PATH
from app.key_rotation import get_active_signing_key, get_active_public_key_b64, get_all_valid_public_keys
from shared.security.keys import load_or_create_signing_key, public_key_b64


def discovery_public_key_b64() -> str:
    """Base64url-encoded Ed25519 public key текущего активного ключа."""
    try:
        return get_active_public_key_b64()
    except Exception:
        # Fallback на файловый ключ если БД ещё не инициализирована
        return public_key_b64(load_or_create_signing_key(DISCOVERY_SIGNING_KEY_PATH))


def _get_signing_key() -> SigningKey:
    try:
        return get_active_signing_key()
    except Exception:
        return load_or_create_signing_key(DISCOVERY_SIGNING_KEY_PATH)


# ---------------------------------------------------------------------------
# Sign / verify
# ---------------------------------------------------------------------------

def _canonical(user_id: str, home_node_url: str, updated_at: str) -> bytes:
    return f"{user_id}|{home_node_url}|{updated_at}".encode("utf-8")


def sign_user_record(user_id: str, home_node_url: str, updated_at: str) -> str:
    """Return base64url signature over the canonical user record payload."""
    message = _canonical(user_id, home_node_url, updated_at)
    sig = _get_signing_key().sign(message).signature
    return base64.urlsafe_b64encode(sig).decode("ascii")


def verify_user_record(
    user_id: str,
    home_node_url: str,
    updated_at: str,
    signature_b64: str,
    public_key_b64_str: str,
) -> bool:
    """
    Verify a signed user record.  Returns True on success, False on any failure.
    Intentionally swallows all exceptions so callers don't need try/except.
    """
    try:
        key_bytes = base64.urlsafe_b64decode(public_key_b64_str.encode())
        sig_bytes = base64.urlsafe_b64decode(signature_b64.encode())
        message = _canonical(user_id, home_node_url, updated_at)
        VerifyKey(key_bytes).verify(message, sig_bytes)
        return True
    except (BadSignatureError, Exception):
        return False
