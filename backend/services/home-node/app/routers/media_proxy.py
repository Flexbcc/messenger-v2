import httpx
from fastapi import APIRouter, Depends, HTTPException
from fastapi.responses import Response

from app.config import settings
from app.deps import get_current_device
from app.fed_security import get_federation_security
from app.federation import _resolve_media_url
from shared.security.http_client import federation_get
from shared.security.media_token import mint_media_access_token

router = APIRouter(prefix="/media", tags=["media"])


@router.get("/{media_id}")
async def download_media_proxy(
    media_id: str,
    current: tuple[str, str] = Depends(get_current_device),
):
    """JWT-authenticated media download via home-node (production path)."""
    _user_id, _device_id = current
    fs = get_federation_security()
    media_url = await _resolve_media_url()
    async with httpx.AsyncClient(timeout=30.0) as client:
        resp = await federation_get(
            client,
            f"{media_url}/media/{media_id}",
            path=f"/media/{media_id}",
            signing_key=fs.signing_key,
            node_id=fs.node_id,
        )
    if resp.status_code != 200:
        raise HTTPException(status_code=resp.status_code, detail="Media not found")
    return Response(content=resp.content, media_type="application/octet-stream")


@router.get("/{media_id}/access-url")
async def media_access_url(
    media_id: str,
    current: tuple[str, str] = Depends(get_current_device),
):
    """Mint a short-lived signed URL for direct media-node download."""
    user_id, _device_id = current
    media_url = await _resolve_media_url()
    token = mint_media_access_token(
        media_id=media_id,
        user_id=user_id,
        secret=settings.media_access_secret,
        ttl_seconds=settings.media_access_ttl_seconds,
    )
    return {
        "url": f"{media_url}/media/{media_id}?access_token={token}",
        "expires_in": settings.media_access_ttl_seconds,
    }
