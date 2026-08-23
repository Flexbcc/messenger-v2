from functools import lru_cache

from fastapi import Depends, Request

from app.config import settings
from shared.security.runtime import FederationSecurity
from shared.security.service_access import authorize_service_request


@lru_cache
def get_federation_security() -> FederationSecurity:
    return FederationSecurity(
        discovery_url=settings.discovery_url,
        node_id=settings.node_id,
        signing_key_path=settings.signing_key_path,
        root_key_path=settings.root_key_path,
        operational_certificate_path=settings.operational_certificate_path,
        nonce_db_path=settings.federation_nonce_db_path,
    )


async def require_media_upload(request: Request) -> str:
    fs = get_federation_security()
    return await authorize_service_request(
        request,
        trust_cache=fs.trust_cache,
        nonce_store=fs.nonce_store,
        path="/media",
        jwt_secret=settings.jwt_secret,
        allow_jwt=True,
    )


async def require_media_download(request: Request, media_id: str) -> str:
    fs = get_federation_security()
    return await authorize_service_request(
        request,
        trust_cache=fs.trust_cache,
        nonce_store=fs.nonce_store,
        path=f"/media/{media_id}",
        jwt_secret=settings.jwt_secret,
        allow_jwt=True,
        media_id=media_id,
        media_token_secret=settings.media_access_secret,
    )
