"""Strict validation for browser Web Push subscription endpoints."""

from __future__ import annotations

import base64
import ipaddress
import json
import math
import os
import re
from functools import lru_cache
from urllib.parse import urlsplit


_DEFAULT_HOST_SUFFIXES = (
    "fcm.googleapis.com",
    "updates.push.services.mozilla.com",
    "web.push.apple.com",
)
_HOST_PATTERN = re.compile(r"^[a-z0-9](?:[a-z0-9.-]{0,251}[a-z0-9])?$")


@lru_cache
def allowed_webpush_host_suffixes() -> tuple[str, ...]:
    raw = os.environ.get("WEBPUSH_ALLOWED_HOST_SUFFIXES", "").strip()
    values = raw.split(",") if raw else _DEFAULT_HOST_SUFFIXES
    result = tuple(
        dict.fromkeys(value.strip().lower().lstrip(".") for value in values if value.strip())
    )
    if not 1 <= len(result) <= 32:
        raise RuntimeError("WEBPUSH_ALLOWED_HOST_SUFFIXES must contain 1 to 32 hosts")
    if any(
        len(value) > 253
        or not _HOST_PATTERN.fullmatch(value)
        or ".." in value
        for value in result
    ):
        raise RuntimeError("WEBPUSH_ALLOWED_HOST_SUFFIXES contains an invalid host")
    for value in result:
        try:
            ipaddress.ip_address(value)
        except ValueError:
            continue
        raise RuntimeError("WEBPUSH_ALLOWED_HOST_SUFFIXES must not contain IP addresses")
    return result


def _valid_base64url(value: object, *, minimum: int, maximum: int) -> bool:
    if not isinstance(value, str) or not minimum <= len(value) <= maximum:
        return False
    try:
        padded = value + "=" * (-len(value) % 4)
        base64.b64decode(padded, altchars=b"-_", validate=True)
    except (ValueError, TypeError):
        return False
    return True


def validate_vapid_public_key(value: object) -> str:
    """Validate a canonical uncompressed P-256 VAPID public key."""
    if not isinstance(value, str) or len(value) != 87 or "=" in value:
        raise ValueError("VAPID public key has an invalid encoding")
    try:
        decoded = base64.urlsafe_b64decode(value + "=")
    except (ValueError, TypeError) as exc:
        raise ValueError("VAPID public key has an invalid encoding") from exc
    canonical = base64.urlsafe_b64encode(decoded).decode("ascii").rstrip("=")
    if len(decoded) != 65 or decoded[0] != 0x04 or canonical != value:
        raise ValueError("VAPID public key must be an uncompressed P-256 key")
    return value


def validate_webpush_subscription_json(raw: str) -> dict:
    if not isinstance(raw, str) or not 1 <= len(raw) <= 16_384:
        raise ValueError("Web Push subscription size is invalid")
    try:
        payload = json.loads(raw)
    except (ValueError, TypeError) as exc:
        raise ValueError("Web Push subscription is not valid JSON") from exc
    if not isinstance(payload, dict) or not set(payload).issubset(
        {"endpoint", "expirationTime", "keys"}
    ):
        raise ValueError("Web Push subscription shape is invalid")
    endpoint = payload.get("endpoint")
    keys = payload.get("keys")
    if not isinstance(endpoint, str) or not 1 <= len(endpoint) <= 2048:
        raise ValueError("Web Push endpoint is invalid")
    parsed = urlsplit(endpoint)
    host = (parsed.hostname or "").lower()
    allowed = allowed_webpush_host_suffixes()
    if (
        parsed.scheme != "https"
        or not host
        or parsed.username
        or parsed.password
        or parsed.fragment
        or parsed.port not in (None, 443)
        or not any(host == suffix or host.endswith("." + suffix) for suffix in allowed)
    ):
        raise ValueError("Web Push endpoint host is not allowed")
    if not isinstance(keys, dict) or set(keys) != {"p256dh", "auth"}:
        raise ValueError("Web Push subscription keys are invalid")
    if not _valid_base64url(keys.get("p256dh"), minimum=40, maximum=256):
        raise ValueError("Web Push p256dh key is invalid")
    if not _valid_base64url(keys.get("auth"), minimum=16, maximum=128):
        raise ValueError("Web Push auth key is invalid")
    expiration = payload.get("expirationTime")
    if expiration is not None and (
        not isinstance(expiration, (int, float))
        or isinstance(expiration, bool)
        or not math.isfinite(expiration)
        or expiration < 0
    ):
        raise ValueError("Web Push expiration time is invalid")
    return payload
