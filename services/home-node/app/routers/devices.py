"""
Exposes a user's identity_key_bundle so a sender can establish an X3DH
session before the first message (see shared/README.md Crypto API).

API versioning (Phase C2):
  GET .../prekey-bundle       — follows PREKEY_CONSUMPTION_MODE (legacy default)
  GET .../prekey-bundle?v=0 — force legacy (full bundle, no consumption)
  GET .../prekey-bundle?v=1 — force strict (one OTP prekey, api_version in response)
"""
from typing import Optional

import httpx
from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel, Field
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import settings
from app.db import get_db
from app.deps import get_current_device
from app.federation import resolve_home_node
from app.models import Device
from app.prekeys import (
    PREKEY_CONSUMPTION_MODE,
    build_prekey_response,
    count_unused_prekeys,
    merge_prekeys,
    resolve_prekey_mode,
)

router = APIRouter(tags=["devices"])

SUPPORTED_PREKEY_API_VERSIONS = {0, 1}


class PreKeyUploadRequest(BaseModel):
    prekeys: list[dict] = Field(..., min_length=1)


def _validate_api_version(v: Optional[int]) -> Optional[int]:
    if v is None:
        return None
    if v not in SUPPORTED_PREKEY_API_VERSIONS:
        raise HTTPException(
            status_code=400,
            detail=f"Unsupported prekey API version {v}; use v=0 or v=1",
        )
    return v


@router.get("/users/{user_id}/prekey-bundle")
async def get_prekey_bundle(
    user_id: str,
    v: Optional[int] = Query(default=None, description="Prekey API version: 0=legacy, 1=strict"),
    db: AsyncSession = Depends(get_db),
):
    api_version = _validate_api_version(v)
    result = await db.execute(select(Device).where(Device.user_id == user_id))
    device = result.scalars().first()
    if device:
        return await build_prekey_response(device, db, api_version=api_version)

    home_node_url = await resolve_home_node(user_id)
    if not home_node_url or home_node_url == settings.public_url:
        raise HTTPException(status_code=404, detail="Unknown user_id")

    params = {}
    if api_version is not None:
        params["v"] = str(api_version)

    async with httpx.AsyncClient(timeout=5.0) as client:
        resp = await client.get(f"{home_node_url}/users/{user_id}/prekey-bundle", params=params)
    if resp.status_code != 200:
        raise HTTPException(status_code=404, detail="Unknown user_id on remote node")
    return resp.json()


@router.post("/devices/{device_id}/prekeys")
async def upload_prekeys(
    device_id: str,
    payload: PreKeyUploadRequest,
    v: Optional[int] = Query(default=None, description="Echo api_version in response when v=1"),
    current: tuple[str, str] = Depends(get_current_device),
    db: AsyncSession = Depends(get_db),
):
    api_version = _validate_api_version(v)
    user_id, caller_device_id = current
    if caller_device_id != device_id:
        raise HTTPException(status_code=403, detail="Can only upload prekeys for your own device")

    device = await db.get(Device, device_id)
    if not device or device.user_id != user_id:
        raise HTTPException(status_code=404, detail="Device not found")

    device.identity_key_bundle = merge_prekeys(device.identity_key_bundle or {}, payload.prekeys)
    await db.commit()

    unused = count_unused_prekeys(device.identity_key_bundle)
    low_threshold = 5
    response = {
        "status": "ok",
        "unused_prekeys": unused,
        "low_prekey_warning": unused < low_threshold,
        "prekey_mode": resolve_prekey_mode(api_version) if api_version is not None else PREKEY_CONSUMPTION_MODE,
    }
    if api_version is not None:
        response["api_version"] = api_version
    return response
