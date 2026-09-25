"""PreKey HTTP layer for home-node."""
from typing import Optional

from fastapi import HTTPException
from sqlalchemy import select, update
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
    current = device
    for _ in range(5):
        bundle = current.identity_key_bundle or {}
        try:
            response = build_prekey_bundle_response(
                current.id, bundle, api_version=api_version
            )
        except ValueError as exc:
            raise HTTPException(
                status_code=503,
                detail="No one-time prekeys available; upload more via POST /devices/{device_id}/prekeys",
            ) from exc

        updated = response.pop("_updated_bundle", None)
        if updated is None:
            return response

        # Compare-and-swap prevents concurrent readers from receiving the
        # same one-time prekey. A stale bundle updates zero rows, at which
        # point we reload and consume a different still-unused key.
        write = await db.execute(
            update(Device)
            .where(
                Device.id == current.id,
                Device.identity_key_bundle == bundle,
            )
            .values(identity_key_bundle=updated)
        )
        if write.rowcount == 1:
            await db.commit()
            response["unused_prekeys"] = count_unused_prekeys(updated)
            return response

        await db.rollback()
        refreshed = await db.execute(select(Device).where(Device.id == current.id))
        current = refreshed.scalar_one_or_none()
        if current is None:
            raise HTTPException(status_code=404, detail="Device not found")

    raise HTTPException(
        status_code=409,
        detail="Prekey bundle changed concurrently; retry the request",
    )
