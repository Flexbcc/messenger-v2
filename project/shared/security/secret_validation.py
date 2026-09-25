"""Small fail-fast helpers for runtime secret configuration."""

import hmac
from collections.abc import Mapping


DEVELOPMENT_SECRET_VALUES = frozenset(
    {
        "changeme",
        "change-me-please",
        "changeme-push-secret",
        "dev-secret-change-me-in-production",
        "dev-only-insecure-secret-change-me",
        "dev-local-secret",
        "dev-local-turn-secret",
        "dev-local-admin-secret",
    }
)


def require_strong_secret(name: str, value: str, *, minimum_bytes: int = 32) -> None:
    if not value or len(value.encode("utf-8")) < minimum_bytes:
        raise RuntimeError(f"{name} must contain at least {minimum_bytes} bytes")
    if value in DEVELOPMENT_SECRET_VALUES:
        raise RuntimeError(f"{name} must not use a development default")


def require_configured_secret(name: str, value: str, *, minimum_bytes: int = 16) -> None:
    """Reject absent, trivially short, and repository-known credentials."""
    require_strong_secret(name, value, minimum_bytes=minimum_bytes)


def require_independent_secrets(secrets: Mapping[str, str]) -> None:
    """Validate strength and reject reuse across security domains."""
    items = list(secrets.items())
    for name, value in items:
        require_strong_secret(name, value)
    for index, (left_name, left_value) in enumerate(items):
        for right_name, right_value in items[index + 1 :]:
            if hmac.compare_digest(left_value, right_value):
                raise RuntimeError(f"{left_name} and {right_name} must be different")
