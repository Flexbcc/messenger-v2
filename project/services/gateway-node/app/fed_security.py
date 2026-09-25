from functools import lru_cache

from app.config import settings
from shared.security.runtime import FederationSecurity


@lru_cache
def get_federation_security() -> FederationSecurity:
    return FederationSecurity(
        discovery_url=settings.discovery_url,
        node_id=settings.node_id,
        signing_key_path=settings.signing_key_path,
        root_key_path=settings.root_key_path,
        operational_certificate_path=settings.operational_certificate_path,
    )
