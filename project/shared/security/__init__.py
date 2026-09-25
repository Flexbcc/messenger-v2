"""Shared federation security (ADR-0011)."""
from shared.security.config import INTERNAL_SECURITY_MODE
from shared.security.federation_auth import (
    federation_auth_dependency,
    sign_federation_request,
    verify_federation_request,
)

__all__ = [
    "INTERNAL_SECURITY_MODE",
    "federation_auth_dependency",
    "sign_federation_request",
    "verify_federation_request",
]
