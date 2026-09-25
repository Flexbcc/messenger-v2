"""Short-lived HMAC tokens for media download URLs (ADR-0011 / P5)."""
import base64
import hashlib
import hmac
import time
from typing import Optional
from urllib.parse import quote, unquote

_MAX_TOKEN_TTL_SECONDS = 3600
_MAX_TOKEN_CHARACTERS = 2048


def _valid_identifier(value: str, maximum: int) -> bool:
    return (
        isinstance(value, str)
        and 0 < len(value) <= maximum
        and "|" not in value
        and not any(character.isspace() for character in value)
    )


def mint_media_access_token(
    *,
    media_id: str,
    user_id: str,
    secret: str,
    ttl_seconds: int = 300,
) -> str:
    if not _valid_identifier(media_id, 512):
        raise ValueError("media_id is invalid")
    if not _valid_identifier(user_id, 256):
        raise ValueError("user_id is invalid")
    if not secret:
        raise ValueError("media token secret is required")
    if not 1 <= ttl_seconds <= _MAX_TOKEN_TTL_SECONDS:
        raise ValueError("media token TTL is outside the supported range")
    expires = int(time.time()) + ttl_seconds
    payload = f"{media_id}|{user_id}|{expires}"
    sig = hmac.new(secret.encode(), payload.encode(), hashlib.sha256).digest()
    token_body = f"{expires}|{user_id}|{base64.urlsafe_b64encode(sig).decode()}"
    return quote(token_body, safe="")


def verify_media_access_token(
    token: str,
    *,
    media_id: str,
    secret: str,
) -> Optional[str]:
    if (
        not token
        or len(token) > _MAX_TOKEN_CHARACTERS
        or not secret
        or not _valid_identifier(media_id, 512)
    ):
        return None
    try:
        raw = unquote(token)
        if len(raw) > _MAX_TOKEN_CHARACTERS:
            return None
        expires_s, user_id, sig_b64 = raw.split("|", 2)
        if not _valid_identifier(user_id, 256) or len(sig_b64) > 64:
            return None
        expires = int(expires_s)
        now = int(time.time())
        if expires < now or expires > now + _MAX_TOKEN_TTL_SECONDS:
            return None
        payload = f"{media_id}|{user_id}|{expires}"
        expected = hmac.new(secret.encode(), payload.encode(), hashlib.sha256).digest()
        provided = base64.b64decode(sig_b64, altchars=b"-_", validate=True)
        if len(provided) != hashlib.sha256().digest_size:
            return None
        if not hmac.compare_digest(expected, provided):
            return None
        return user_id
    except (ValueError, TypeError):
        return None
