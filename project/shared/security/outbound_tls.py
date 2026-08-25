"""Explicit trust configuration for server-to-server HTTP clients."""

from __future__ import annotations

import os


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
