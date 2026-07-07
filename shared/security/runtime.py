"""Lazy singletons for federation security per service process."""
from functools import lru_cache
from typing import Optional

from nacl.signing import SigningKey

from shared.security.audit_log import FederationAuditLog
from shared.security.keys import load_or_create_signing_key, public_key_b64
from shared.security.nonce_store import NonceStore
from shared.security.trust_cache import TrustCache


@lru_cache
def get_signing_key(key_path: str) -> SigningKey:
    return load_or_create_signing_key(key_path)


def signing_public_key_b64(key_path: str) -> str:
    return public_key_b64(get_signing_key(key_path))


class FederationSecurity:
    def __init__(
        self,
        *,
        discovery_url: str,
        node_id: str,
        signing_key_path: str,
        nonce_db_path: Optional[str] = None,
        audit_db_path: Optional[str] = None,
    ):
        self.node_id = node_id
        self.signing_key_path = signing_key_path
        self.trust_cache = TrustCache(discovery_url)
        self.nonce_store = NonceStore(nonce_db_path)
        self.audit_log = FederationAuditLog(audit_db_path)

    @property
    def signing_key(self) -> SigningKey:
        return get_signing_key(self.signing_key_path)

    @property
    def signing_public_key(self) -> str:
        return public_key_b64(self.signing_key)


def federation_registration_fields(signing_key_path: str) -> dict[str, str]:
    if not signing_key_path:
        return {}
    return {"signing_public_key": signing_public_key_b64(signing_key_path)}

