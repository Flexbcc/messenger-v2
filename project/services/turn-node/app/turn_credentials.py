"""
Time-limited TURN credentials via the widely-used "TURN REST API" scheme
(shared secret, HMAC-SHA1 — compatible with coturn's `use-auth-secret` +
`static-auth-secret`). This module only issues credentials; it does not
implement TURN relaying itself (see spec/0605_TURN_NODE.md → Назначение —
that's deliberately left to a real TURN server sharing this secret).
"""
import base64
import hashlib
import hmac
import time

from app.config import settings


def issue_credentials() -> dict:
    expiry = int(time.time()) + settings.credential_ttl_seconds
    username = str(expiry)
    digest = hmac.new(settings.shared_secret.encode(), username.encode(), hashlib.sha1).digest()
    password = base64.b64encode(digest).decode()
    return {
        "username": username,
        "password": password,
        "ttl": settings.credential_ttl_seconds,
        "uris": [
            f"turn:{settings.turn_host}:{settings.turn_port}?transport=udp",
            f"turn:{settings.turn_host}:{settings.turn_port}?transport=tcp",
        ],
    }
