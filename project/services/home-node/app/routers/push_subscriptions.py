"""Authenticated client bridge to the internal Push Proxy."""
import json

import httpx
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel

from app.config import settings
from app.deps import get_current_device

router = APIRouter(prefix="/users/me/push", tags=["push"])


class WebPushSubscription(BaseModel):
    subscription: str


async def _proxy(method: str, path: str, *, json: dict | None = None):
    if not settings.push_proxy_url:
        raise HTTPException(status_code=503, detail="Push service is not configured")
    try:
        async with httpx.AsyncClient(timeout=8) as client:
            response = await client.request(
                method,
                f"{settings.push_proxy_url}{path}",
                json=json,
                headers={"X-Push-Secret": settings.push_proxy_secret},
            )
    except httpx.HTTPError as exc:
        raise HTTPException(status_code=503, detail="Push service unavailable") from exc
    if response.status_code >= 400:
        raise HTTPException(status_code=502, detail="Push service rejected request")
    return response


@router.get("/vapid-key")
async def vapid_key(current: tuple[str, str] = Depends(get_current_device)):
    response = await _proxy("GET", "/internal/vapid-key")
    return response.json()


@router.put("", status_code=204)
async def register_web_push(
    payload: WebPushSubscription,
    current: tuple[str, str] = Depends(get_current_device),
):
    user_id, device_id = current
    if len(payload.subscription) > 16_384:
        raise HTTPException(status_code=400, detail="Push subscription is too large")
    try:
        subscription = json.loads(payload.subscription)
        endpoint = subscription["endpoint"]
        keys = subscription["keys"]
        if (
            not isinstance(endpoint, str)
            or not endpoint.startswith("https://")
            or not isinstance(keys.get("p256dh"), str)
            or not isinstance(keys.get("auth"), str)
        ):
            raise ValueError
    except (KeyError, TypeError, ValueError, json.JSONDecodeError) as exc:
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
    await _proxy("DELETE", f"/internal/tokens/{user_id}/{device_id}")
