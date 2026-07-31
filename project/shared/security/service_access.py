"""Authorize service endpoints via federation headers, JWT, or media access token."""
from typing import Optional

from fastapi import HTTPException, Request

from shared.security.config import (
    HDR_NODE_ID,
    HDR_NONCE,
    HDR_SIGNATURE,
    HDR_TIMESTAMP,
    INTERNAL_SECURITY_MODE,
)
from shared.security.federation_auth import verify_federation_request
from shared.security.jwt_auth import extract_bearer_token, verify_jwt_token
from shared.security.media_token import verify_media_access_token
from shared.security.nonce_store import NonceStore
from shared.security.trust_cache import TrustCache


def _mode_legacy() -> bool:
    return INTERNAL_SECURITY_MODE in ("legacy", "off", "")


def _has_federation_headers(request: Request) -> bool:
    return all(
        request.headers.get(h)
        for h in (HDR_NODE_ID, HDR_TIMESTAMP, HDR_NONCE, HDR_SIGNATURE)
    )


async def authorize_service_request(
    request: Request,
    *,
    trust_cache: TrustCache,
    nonce_store: NonceStore,
    path: Optional[str] = None,
    jwt_secret: str = "",
    allow_jwt: bool = True,
    media_id: Optional[str] = None,
    media_token_secret: Optional[str] = None,
) -> str:
    """
    Returns auth subject: node_id (federation), user_id (jwt/token), or 'legacy'.
    """
    if _mode_legacy():
        return "legacy"

    if _has_federation_headers(request):
        return await verify_federation_request(
            request,
            trust_cache=trust_cache,
            nonce_store=nonce_store,
            path=path or request.url.path,
        )

    if allow_jwt and jwt_secret:
        token = extract_bearer_token(request.headers.get("Authorization"))
        if token:
            payload = verify_jwt_token(token, jwt_secret)
            if payload and payload.get("sub"):
                return str(payload["sub"])

    if media_id and media_token_secret:
        access_token = request.query_params.get("access_token")
        user_id = verify_media_access_token(
            access_token or "",
            media_id=media_id,
            secret=media_token_secret,
        )
        if user_id:
            return user_id

    raise HTTPException(status_code=401, detail="Authentication required")
