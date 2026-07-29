"""Lazy singletons for federation security per service process."""
from functools import lru_cache
from typing import Optional

from nacl.public import PrivateKey
from nacl.signing import SigningKey

from shared.security.audit_log import FederationAuditLog
from shared.security.keys import load_or_create_signing_key, public_key_b64
from shared.security.nonce_store import NonceStore
from shared.security.sealed_sender import curve_public_key_b64, get_or_create_curve_key
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
        curve_key_path: Optional[str] = None,
    ):
        self.node_id = node_id
        self.signing_key_path = signing_key_path
        self._curve_key_path = curve_key_path
        self.trust_cache = TrustCache(discovery_url)
        self.nonce_store = NonceStore(nonce_db_path)
        self.audit_log = FederationAuditLog(audit_db_path)

    @property
    def signing_key(self) -> SigningKey:
        return get_signing_key(self.signing_key_path)

    @property
    def signing_public_key(self) -> str:
        return public_key_b64(self.signing_key)

    @property
    def curve_private_key(self) -> Optional[PrivateKey]:
        """X25519 private key for sealed sender decryption. None if not configured."""
        if not self._curve_key_path:
            return None
        return get_or_create_curve_key(self._curve_key_path)

    @property
    def curve_public_key(self) -> Optional[str]:
        """X25519 public key (base64) to publish in /health for sealed sender."""
        pk = self.curve_private_key
        if pk is None:
            return None
        return curve_public_key_b64(pk)


def federation_registration_fields(signing_key_path: str) -> dict[str, str]:
    if not signing_key_path:
        return {}
    return {"signing_public_key": signing_public_key_b64(signing_key_path)}

