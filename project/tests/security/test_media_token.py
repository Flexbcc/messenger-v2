import base64
import hashlib
import hmac
import time
from urllib.parse import quote

from shared.security.media_token import mint_media_access_token, verify_media_access_token


def test_media_access_token_roundtrip():
    secret = "test-secret"
    media_id = "abc123"
    user_id = "user-1"
    token = mint_media_access_token(
        media_id=media_id,
        user_id=user_id,
        secret=secret,
        ttl_seconds=60,
    )
    assert verify_media_access_token(token, media_id=media_id, secret=secret) == user_id


def test_media_access_token_wrong_media():
    secret = "test-secret"
    token = mint_media_access_token(media_id="a", user_id="u", secret=secret, ttl_seconds=60)
    assert verify_media_access_token(token, media_id="b", secret=secret) is None


def test_media_access_token_expired():
    secret = "test-secret"
    expires = int(time.time()) - 1
    payload = f"a|u|{expires}"
    signature = hmac.new(secret.encode(), payload.encode(), hashlib.sha256).digest()
    token = quote(
        f"{expires}|u|{base64.urlsafe_b64encode(signature).decode()}", safe=""
    )
    assert verify_media_access_token(token, media_id="a", secret=secret) is None
