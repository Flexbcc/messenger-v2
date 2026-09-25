import logging
from typing import Annotated

import httpx
from fastapi import APIRouter, Depends, HTTPException, Path
from fastapi.responses import Response
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import settings
from app.db import get_db
from app.deps import get_current_device
from app.fed_security import get_federation_security
from app.federation import _resolve_media_url
from app.models import (
    ConversationParticipant,
    FederatedMediaRef,
    MessageMediaRef,
)
from shared.security.http_client import federation_get_stream
from shared.security.media_id import MEDIA_ID_PATTERN
from shared.security.media_token import mint_media_access_token

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/media", tags=["media"])


async def _fetch_media(client: httpx.AsyncClient, media_url: str, media_id: str) -> httpx.Response:
    """Скачать медиафайл у указанного Media-node через federation GET."""
    fs = get_federation_security()
    return await federation_get_stream(
        client,
        f"{media_url}/media/{media_id}",
        path=f"/media/{media_id}",
        signing_key=fs.signing_key,
        node_id=fs.node_id,
    )


async def _read_bounded_media(response: httpx.Response) -> bytes:
    """Read a media response without allowing an upstream memory DoS."""
    try:
        raw_length = response.headers.get("content-length")
        if raw_length is not None:
            try:
                content_length = int(raw_length)
            except ValueError as exc:
                raise HTTPException(
                    status_code=502, detail="Media node returned an invalid response"
                ) from exc
            if content_length < 0 or content_length > settings.media_proxy_max_bytes:
                raise HTTPException(
                    status_code=502, detail="Media node response is too large"
                )

        content = bytearray()
        async for chunk in response.aiter_bytes():
            if len(content) + len(chunk) > settings.media_proxy_max_bytes:
                raise HTTPException(
                    status_code=502, detail="Media node response is too large"
                )
            content.extend(chunk)
        return bytes(content)
    except httpx.HTTPError as exc:
        raise HTTPException(
            status_code=502, detail="Media node response failed"
        ) from exc
    finally:
        await response.aclose()


async def _close_and_status(response: httpx.Response) -> int:
    status_code = response.status_code
    await response.aclose()
    return status_code


async def _find_origin_media_url(db: AsyncSession, media_id: str) -> str | None:
    """Ищет origin_media_node_url в FederatedMediaRef по media_id.

    Storage federation (Task #63): клиент при отправке сообщения с медиа
    передаёт media_ids[] + media_node_url. Сервер сохраняет маппинг в
    FederatedMediaRef. Здесь делаем точечный lookup по media_id.
    """
    ref = await db.get(FederatedMediaRef, media_id)
    return ref.origin_media_node_url if ref else None


async def _assert_media_access(
    db: AsyncSession, *, media_id: str, user_id: str
) -> None:
    allowed = await db.scalar(
        select(MessageMediaRef.media_id)
        .join(
            ConversationParticipant,
            ConversationParticipant.conversation_id
            == MessageMediaRef.conversation_id,
        )
        .where(
            MessageMediaRef.media_id == media_id,
            ConversationParticipant.user_id == user_id,
        )
        .limit(1)
    )
    if allowed is not None:
        return
    raise HTTPException(status_code=404, detail="Media not found")


@router.get("/{media_id}")
async def download_media_proxy(
    media_id: Annotated[str, Path(pattern=MEDIA_ID_PATTERN)],
    current: tuple[str, str] = Depends(get_current_device),
    db: AsyncSession = Depends(get_db),
):
    """JWT-authenticated media download via home-node (production path).

    Storage federation fallback (Task #63): если локальный Media-node не нашёл
    файл (404), пробуем скачать у origin_media_node_url из envelope сообщения.
    Это позволяет получателям на других Home-node скачивать медиа отправителя
    без прямого доступа к чужому Media-node.
    """
    user_id, _device_id = current
    await _assert_media_access(db, media_id=media_id, user_id=user_id)
    local_media_url = await _resolve_media_url()

    async with httpx.AsyncClient(
        timeout=30.0, follow_redirects=False, trust_env=False
    ) as client:
        try:
            resp = await _fetch_media(client, local_media_url, media_id)
        except httpx.HTTPError as exc:
            logger.warning("Local media fetch failed: %s", exc)
            raise HTTPException(status_code=502, detail="Media node unavailable")

        if resp.status_code == 200:
            content = await _read_bounded_media(resp)
            return Response(content=content, media_type="application/octet-stream")

        if resp.status_code != 404:
            await resp.aclose()
            raise HTTPException(status_code=502, detail="Media node rejected request")
        await resp.aclose()

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
            status_code = await _close_and_status(fed_resp)
            if status_code != 404:
                status_code = 502
            raise HTTPException(
                status_code=status_code, detail="Media not found (federation)"
            )

        content = await _read_bounded_media(fed_resp)
        return Response(content=content, media_type="application/octet-stream")


@router.get("/{media_id}/access-url")
async def media_access_url(
    media_id: Annotated[str, Path(pattern=MEDIA_ID_PATTERN)],
    current: tuple[str, str] = Depends(get_current_device),
    db: AsyncSession = Depends(get_db),
):
    """Mint a short-lived signed URL for direct media-node download."""
    user_id, _device_id = current
    await _assert_media_access(db, media_id=media_id, user_id=user_id)
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
