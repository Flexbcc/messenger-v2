"""Authenticated client bridge to the internal Push Proxy."""
import json
from urllib.parse import quote

import httpx
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, ConfigDict, Field

from app.config import settings
from app.deps import get_current_device
from shared.security.webpush import (
    validate_vapid_public_key,
    validate_webpush_subscription_json,
)

router = APIRouter(prefix="/users/me/push", tags=["push"])
MAX_PUSH_PROXY_RESPONSE_BYTES = 64 * 1024


class WebPushSubscription(BaseModel):
    model_config = ConfigDict(extra="forbid")
    subscription: str = Field(min_length=1, max_length=16_384)


async def _proxy(method: str, path: str, *, json: dict | None = None):
    if not settings.push_proxy_url:
        raise HTTPException(status_code=503, detail="Push service is not configured")
    try:
        async with httpx.AsyncClient(
            timeout=8,
            follow_redirects=False,
            trust_env=False,
        ) as client:
            async with client.stream(
                method,
                f"{settings.push_proxy_url}{path}",
                json=json,
                headers={"X-Push-Secret": settings.push_proxy_secret},
            ) as response:
                if response.status_code >= 400:
                    raise HTTPException(
                        status_code=502,
                        detail="Push service rejected request",
                    )
                declared = response.headers.get("content-length")
                if declared is not None:
                    try:
                        declared_size = int(declared)
                    except ValueError as exc:
                        raise HTTPException(
                            status_code=502,
                            detail="Push service returned an invalid response",
                        ) from exc
                    if not 0 <= declared_size <= MAX_PUSH_PROXY_RESPONSE_BYTES:
                        raise HTTPException(
                            status_code=502,
                            detail="Push service response is too large",
                        )
                body = bytearray()
                async for chunk in response.aiter_bytes():
                    if len(body) + len(chunk) > MAX_PUSH_PROXY_RESPONSE_BYTES:
                        raise HTTPException(
                            status_code=502,
                            detail="Push service response is too large",
                        )
                    body.extend(chunk)
                return bytes(body)
    except httpx.HTTPError as exc:
        raise HTTPException(status_code=503, detail="Push service unavailable") from exc


@router.get("/vapid-key")
async def vapid_key(current: tuple[str, str] = Depends(get_current_device)):
    raw = await _proxy("GET", "/internal/vapid-key")
    try:
        payload = json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise HTTPException(
            status_code=502,
            detail="Push service returned an invalid response",
        ) from exc
    if not isinstance(payload, dict) or set(payload) != {"public_key"}:
        raise HTTPException(
            status_code=502,
            detail="Push service returned an invalid response",
        )
    try:
        validate_vapid_public_key(payload["public_key"])
    except ValueError as exc:
        raise HTTPException(
            status_code=502,
            detail="Push service returned an invalid VAPID key",
        ) from exc
    return payload


@router.put("", status_code=204)
async def register_web_push(
    payload: WebPushSubscription,
    current: tuple[str, str] = Depends(get_current_device),
):
    user_id, device_id = current
    try:
        validate_webpush_subscription_json(payload.subscription)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail="Invalid Web Push subscription") from exc
    await _proxy("PUT", "/internal/tokens", json={
        "user_id": user_id,
        "device_id": device_id,
        "platform": "webpush",
        "token": payload.subscription,
    })


@router.delete("", status_code=204)
async def delete_web_push(current: tuple[str, str] = Depends(get_current_device)):
    user_id, device_id = current
    await _proxy(
        "DELETE",
        f"/internal/tokens/{quote(user_id, safe='')}/{quote(device_id, safe='')}",
    )
