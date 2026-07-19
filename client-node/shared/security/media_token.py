"""Short-lived HMAC tokens for media download URLs (ADR-0011 / P5)."""
import base64
import hashlib
import hmac
import time
from typing import Optional
from urllib.parse import quote, unquote


def mint_media_access_token(
    *,
    media_id: str,
    user_id: str,
    secret: str,
    ttl_seconds: int = 300,
) -> str:
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
    if not token or not secret:
        return None
    try:
        raw = unquote(token)
        expires_s, user_id, sig_b64 = raw.split("|", 2)
        expires = int(expires_s)
        if expires < int(time.time()):
            return None
        payload = f"{media_id}|{user_id}|{expires}"
        expected = hmac.new(secret.encode(), payload.encode(), hashlib.sha256).digest()
        if not hmac.compare_digest(expected, base64.urlsafe_b64decode(sig_b64.encode())):
            return None
        return user_id
    except (ValueError, TypeError):
        return None
