"""
Exposes a user's identity_key_bundle so a sender can establish an X3DH
session before the first message (see shared/README.md Crypto API).

API versioning (Phase C2):
  GET .../prekey-bundle       — follows PREKEY_CONSUMPTION_MODE (strict default)
  GET .../prekey-bundle?v=0 — legacy response only when server policy allows it
  GET .../prekey-bundle?v=1 — strict (one OTP prekey, api_version in response)
"""
import re
from typing import Optional

import httpx
from fastapi import APIRouter, Depends, HTTPException, Query, Request
from pydantic import BaseModel, Field
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import settings
from app.db import get_db
from app.deps import get_current_device
from app.federation import resolve_home_node
from app.models import Device
from app.schemas import IdentityKeyBundle, PublicPreKey
from shared.security.metrics import RateLimiter, metrics
from app.prekeys import (
    PREKEY_CONSUMPTION_MODE,
    build_prekey_response,
    count_unused_prekeys,
    merge_prekeys,
    resolve_prekey_mode,
)

router = APIRouter(tags=["devices"])

SUPPORTED_PREKEY_API_VERSIONS = {0, 1}
_USER_ID_PATTERN = re.compile(r"^[A-Za-z0-9_.:-]{1,128}$")
_public_prekey_ip_limiter = RateLimiter(
    rate=10.0,
    capacity=300,
    max_buckets=50_000,
    idle_ttl_seconds=3600,
)
_public_prekey_target_limiter = RateLimiter(
    rate=1 / 30,
    capacity=30,
    max_buckets=50_000,
    idle_ttl_seconds=3600,
)
_authenticated_prekey_limiter = RateLimiter(
    rate=1.0,
    capacity=60,
    max_buckets=50_000,
    idle_ttl_seconds=3600,
)


def _require_prekey_capacity(*keys_and_limiters: tuple[str, RateLimiter]) -> None:
    for key, limiter in keys_and_limiters:
        if limiter.allow(key):
            continue
        metrics().rate_limit_hits += 1
        raise HTTPException(
            status_code=429,
            detail="Prekey request rate limit exceeded",
        )


class PreKeyUploadRequest(BaseModel):
    model_config = {"extra": "forbid"}
    prekeys: list[PublicPreKey] = Field(..., min_length=1, max_length=256)


class IdentityBundleUpdateRequest(BaseModel):
    model_config = {"extra": "forbid"}
    identity_key_bundle: IdentityKeyBundle


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
    request: Request,
    v: Optional[int] = Query(default=None, description="Prekey API version: 0=legacy, 1=strict"),
    db: AsyncSession = Depends(get_db),
):
    if not _USER_ID_PATTERN.fullmatch(user_id):
        raise HTTPException(status_code=404, detail="Unknown user_id")
    client_host = request.client.host if request.client else "unknown"
    _require_prekey_capacity(
        (f"ip:{client_host}", _public_prekey_ip_limiter),
        (f"target:{user_id}", _public_prekey_target_limiter),
    )
    api_version = _validate_api_version(v)
    # Compatibility endpoint for old account-wide clients. Selection is stable
    # and prefers the most recently active device; current clients use the
    # explicit /users/{user}/devices/{device}/prekey-bundle endpoint instead.
    result = await db.execute(
        select(Device)
        .where(Device.user_id == user_id, Device.trusted.is_(True))
        .order_by(Device.last_active.desc(), Device.id.asc())
        .limit(1)
    )
    device = result.scalars().first()
    if device:
        return await build_prekey_response(device, db, api_version=api_version)

    home_node_url = await resolve_home_node(user_id)
    if not home_node_url or home_node_url == settings.public_url:
        raise HTTPException(status_code=404, detail="Unknown user_id")

    params = {}
    if api_version is not None:
        params["v"] = str(api_version)

    async with httpx.AsyncClient(
        timeout=5.0, follow_redirects=False, trust_env=False
    ) as client:
        resp = await client.get(f"{home_node_url}/users/{user_id}/prekey-bundle", params=params)
    if resp.status_code != 200:
        raise HTTPException(status_code=404, detail="Unknown user_id on remote node")
    return resp.json()


@router.get("/users/{user_id}/devices/{device_id}/prekey-bundle")
async def get_device_prekey_bundle(
    user_id: str,
    device_id: str,
    current: tuple[str, str] = Depends(get_current_device),
    db: AsyncSession = Depends(get_db),
):
    _caller_user_id, caller_device_id = current
    _require_prekey_capacity(
        (f"caller:{caller_device_id}", _authenticated_prekey_limiter),
        (f"target:{user_id}", _public_prekey_target_limiter),
    )
    device = await db.get(Device, device_id)
    if not device or device.user_id != user_id or not device.trusted:
        raise HTTPException(status_code=404, detail="Device not found")
    return await build_prekey_response(device, db, api_version=1)


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

    device.identity_key_bundle = merge_prekeys(
        device.identity_key_bundle or {},
        [prekey.model_dump() for prekey in payload.prekeys],
    )
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


@router.put("/devices/{device_id}/identity-bundle")
async def replace_identity_bundle(
    device_id: str,
    payload: IdentityBundleUpdateRequest,
    current: tuple[str, str] = Depends(get_current_device),
    db: AsyncSession = Depends(get_db),
):
    """Publish the exact bundle backed by this device's current private keys."""
    user_id, caller_device_id = current
    if caller_device_id != device_id:
        raise HTTPException(status_code=403, detail="Can only update your own device")
    device = await db.get(Device, device_id)
    if not device or device.user_id != user_id:
        raise HTTPException(status_code=404, detail="Device not found")
    device.identity_key_bundle = payload.identity_key_bundle.model_dump()
    await db.commit()
    return {
        "status": "ok",
        "unused_prekeys": count_unused_prekeys(device.identity_key_bundle),
    }
