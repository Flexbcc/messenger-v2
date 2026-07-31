import logging

import httpx
from fastapi import APIRouter, Depends, HTTPException
from fastapi.responses import Response
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import settings
from app.db import get_db
from app.deps import get_current_device
from app.fed_security import get_federation_security
from app.federation import _resolve_media_url
from app.models import FederatedMediaRef
from shared.security.http_client import federation_get
from shared.security.media_token import mint_media_access_token

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/media", tags=["media"])


async def _fetch_media(client: httpx.AsyncClient, media_url: str, media_id: str) -> httpx.Response:
    """Скачать медиафайл у указанного Media-node через federation GET."""
    fs = get_federation_security()
    return await federation_get(
        client,
        f"{media_url}/media/{media_id}",
        path=f"/media/{media_id}",
        signing_key=fs.signing_key,
        node_id=fs.node_id,
    )


async def _find_origin_media_url(db: AsyncSession, media_id: str) -> str | None:
    """Ищет origin_media_node_url в FederatedMediaRef по media_id.

    Storage federation (Task #63): клиент при отправке сообщения с медиа
    передаёт media_ids[] + media_node_url. Сервер сохраняет маппинг в
    FederatedMediaRef. Здесь делаем точечный lookup по media_id.
    """
    ref = await db.get(FederatedMediaRef, media_id)
    return ref.origin_media_node_url if ref else None


@router.get("/{media_id}")
async def download_media_proxy(
    media_id: str,
    current: tuple[str, str] = Depends(get_current_device),
    db: AsyncSession = Depends(get_db),
):
    """JWT-authenticated media download via home-node (production path).

    Storage federation fallback (Task #63): если локальный Media-node не нашёл
    файл (404), пробуем скачать у origin_media_node_url из envelope сообщения.
    Это позволяет получателям на других Home-node скачивать медиа отправителя
    без прямого доступа к чужому Media-node.
    """
    _user_id, _device_id = current
    local_media_url = await _resolve_media_url()

    async with httpx.AsyncClient(timeout=30.0) as client:
        resp = await _fetch_media(client, local_media_url, media_id)

        if resp.status_code == 200:
            return Response(content=resp.content, media_type="application/octet-stream")

        if resp.status_code != 404:
            raise HTTPException(status_code=resp.status_code, detail="Media error")

        # 404 на локальном Media-node — пробуем federation fallback
        logger.info(
            "Media %s not found on local media-node, trying federation fallback", media_id
        )
        origin_url = await _find_origin_media_url(db, media_id)
        if not origin_url or origin_url.rstrip("/") == local_media_url.rstrip("/"):
            raise HTTPException(status_code=404, detail="Media not found")

        try:
            fed_resp = await _fetch_media(client, origin_url, media_id)
        except httpx.HTTPError as e:
            logger.warning("Federation media fetch from %s failed: %s", origin_url, e)
            raise HTTPException(status_code=502, detail="Federation media fetch failed")

        if fed_resp.status_code != 200:
            raise HTTPException(status_code=fed_resp.status_code, detail="Media not found (federation)")

        return Response(content=fed_resp.content, media_type="application/octet-stream")


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
