from functools import lru_cache

from fastapi import Request

from app.config import (
    DISCOVERY_NODE_ALIAS,
    DISCOVERY_NODE_OPERATIONAL_CERTIFICATE_PATH,
    DISCOVERY_NODE_OPERATIONAL_KEY_PATH,
    DISCOVERY_NODE_ROOT_KEY_PATH,
    DiscoveryRegistrationSettings,
    FEDERATION_AUDIT_DB_PATH,
    FEDERATION_NONCE_DB_PATH,
)
from shared.security.federation_auth import verify_federation_request
from shared.security.runtime import FederationSecurity


@lru_cache
def get_federation_security() -> FederationSecurity:
    return FederationSecurity(
        # Trust lookups are an internal control-plane request.  The advertised
        # public origin can legitimately be a host/LAN address that is not
        # reachable from inside the node container (the local unified-node
        # setup is one example), while DISCOVERY_NODE_URL is the configured
        # service-to-service origin.
        discovery_url=DiscoveryRegistrationSettings.discovery_url,
        node_id=DISCOVERY_NODE_ALIAS,
        signing_key_path=DISCOVERY_NODE_OPERATIONAL_KEY_PATH,
        root_key_path=DISCOVERY_NODE_ROOT_KEY_PATH,
        operational_certificate_path=DISCOVERY_NODE_OPERATIONAL_CERTIFICATE_PATH,
        nonce_db_path=FEDERATION_NONCE_DB_PATH,
        audit_db_path=FEDERATION_AUDIT_DB_PATH,
    )


async def require_federation(request: Request) -> str:
    security = get_federation_security()
    return await verify_federation_request(
        request,
        trust_cache=security.trust_cache,
        nonce_store=security.nonce_store,
        path=request.url.path,
    )
