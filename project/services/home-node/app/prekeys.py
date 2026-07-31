"""PreKey HTTP layer for home-node."""
from typing import Optional

from fastapi import HTTPException
from sqlalchemy.ext.asyncio import AsyncSession

from app.models import Device
from shared.prekeys import (
    PREKEY_CONSUMPTION_MODE,
    build_prekey_bundle_response,
    count_unused_prekeys,
    merge_prekeys,
    resolve_prekey_mode,
)

__all__ = [
    "PREKEY_CONSUMPTION_MODE",
    "build_prekey_response",
    "count_unused_prekeys",
    "merge_prekeys",
    "resolve_prekey_mode",
]


async def build_prekey_response(
    device: Device,
    db: AsyncSession,
    *,
    api_version: Optional[int] = None,
) -> dict:
    bundle = device.identity_key_bundle or {}
    try:
        result = build_prekey_bundle_response(device.id, bundle, api_version=api_version)
    except ValueError as exc:
        raise HTTPException(
            status_code=503,
            detail="No one-time prekeys available; upload more via POST /devices/{device_id}/prekeys",
        ) from exc

    updated = result.pop("_updated_bundle", None)
    if updated is not None:
        device.identity_key_bundle = updated
        await db.commit()
        result["unused_prekeys"] = count_unused_prekeys(updated)
    return result
