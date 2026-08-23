from functools import lru_cache

from fastapi import Depends, Request

from app.config import settings
from shared.security.federation_auth import verify_federation_request
from shared.security.runtime import FederationSecurity


@lru_cache
def get_federation_security() -> FederationSecurity:
    return FederationSecurity(
        discovery_url=settings.discovery_url,
        node_id=settings.node_id,
        signing_key_path=settings.signing_key_path,
        root_key_path=settings.root_key_path,
        operational_certificate_path=settings.operational_certificate_path,
        nonce_db_path=settings.federation_nonce_db_path,
        audit_db_path=settings.federation_audit_db_path,
    )


async def require_federation(request: Request) -> str:
    fs = get_federation_security()
    return await verify_federation_request(
        request,
        trust_cache=fs.trust_cache,
        nonce_store=fs.nonce_store,
        path=request.url.path,
    )


FederationAuthDep = Depends(require_federation)


async def require_challenge_observer(request: Request) -> str:
    fs = get_federation_security()
    origin = await verify_federation_request(
        request,
        trust_cache=fs.trust_cache,
        nonce_store=fs.nonce_store,
        path=request.url.path,
    )
    if not await fs.trust_cache.is_trusted(origin):
        from fastapi import HTTPException
        raise HTTPException(status_code=403, detail="Trusted challenge observer required")
    return origin


ChallengeObserverAuthDep = Depends(require_challenge_observer)
