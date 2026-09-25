"""
Shared verifier for signed Discovery user records.

Any node (home-node, relay-node, gateway-node) that resolves user→home
via Discovery should call verify_user_record_response() before trusting
the returned home_node_url.

Canonical message: "{user_id}|{home_node_url}|{updated_at}" (UTF-8)
Signature algorithm: Ed25519 (PyNaCl)
Encoding: base64url, no padding
"""
from __future__ import annotations

import base64
import logging

from nacl.signing import VerifyKey
from nacl.exceptions import BadSignatureError

logger = logging.getLogger(__name__)


def _canonical(user_id: str, home_node_url: str, updated_at: str) -> bytes:
    return f"{user_id}|{home_node_url}|{updated_at}".encode("utf-8")


def verify_user_record_response(
    *,
    user_id: str,
    home_node_url: str,
    updated_at: str,
    signature_b64: str,
    public_key_b64: str,
) -> bool:
    """
    Verify Discovery's Ed25519 signature on a user record.

    Returns True on success.  Returns False (never raises) on any failure so
    callers can use a simple ``if not verify_...: return None`` guard.
    """
    try:
        key_bytes = base64.urlsafe_b64decode(_pad(public_key_b64))
        sig_bytes = base64.urlsafe_b64decode(_pad(signature_b64))
        message = _canonical(user_id, home_node_url, updated_at)
        VerifyKey(key_bytes).verify(message, sig_bytes)
        return True
    except BadSignatureError:
        logger.warning(
            "Ed25519 signature mismatch for user record %s→%s", user_id, home_node_url
        )
        return False
    except Exception as exc:
        logger.warning("record_verifier: unexpected error: %s", exc)
        return False


def _pad(b64: str) -> str:
    """Add padding if stripped (urlsafe_b64decode requires it)."""
    rem = len(b64) % 4
    return b64 + "=" * (4 - rem) if rem else b64
