"""Explicit trust configuration for server-to-server HTTP clients."""

from __future__ import annotations

import os
from urllib.parse import urlsplit


def validated_service_origin(value: str, name: str) -> str:
    """Validate an operator-configured HTTP(S) service origin."""
    if not isinstance(value, str) or not 1 <= len(value) <= 2048:
        raise ValueError(f"{name} must be a non-empty HTTP(S) origin")
    parsed = urlsplit(value.strip())
    try:
        parsed.port
    except ValueError as exc:
        raise ValueError(f"{name} has an invalid port") from exc
    if (
        parsed.scheme not in {"http", "https"}
        or not parsed.hostname
        or parsed.username is not None
        or parsed.password is not None
        or parsed.query
        or parsed.fragment
        or parsed.path not in {"", "/"}
    ):
        raise ValueError(f"{name} must be an HTTP(S) origin without credentials or path")
    return value.strip().rstrip("/")


def outbound_tls_verify() -> bool | str:
    """Return httpx's fail-closed verification setting.

    ``trust_env=False`` is retained by callers so proxy-related environment
    variables cannot redirect federation traffic. Operators that use a private
    CA must opt in with an explicit absolute CA bundle path.
    """
    ca_file = os.environ.get("OUO_TLS_CA_FILE", "").strip()
    if not ca_file:
        return True
    if not os.path.isabs(ca_file):
        raise ValueError("OUO_TLS_CA_FILE must be an absolute path")
    if not os.path.isfile(ca_file):
        raise ValueError("OUO_TLS_CA_FILE does not exist")
    return ca_file
