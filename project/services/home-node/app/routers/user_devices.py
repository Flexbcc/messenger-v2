"""Own-account device inventory, trust, key discovery, and revocation."""

from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import get_db
from app.deps import get_current_device, get_current_device_allow_untrusted
from app.key_transparency import append_key_event
from app.models import Device
from app.schemas import DeviceSummaryResponse, DeviceTrustUpdateRequest
from app.ws import manager

router = APIRouter(prefix="/users", tags=["devices"])


@router.get("/me/devices", response_model=list[DeviceSummaryResponse])
async def list_my_devices(
    current: tuple[str, str] = Depends(get_current_device_allow_untrusted),
    db: AsyncSession = Depends(get_db),
):
    user_id, current_device_id = current
    result = await db.execute(
        select(Device)
        .where(Device.user_id == user_id)
        .order_by(Device.last_active.desc())
    )
    devices = result.scalars().all()
    return [
        DeviceSummaryResponse(
            id=device.id,
            device_name=device.device_name,
            device_type=device.device_type,
            created_at=device.created_at,
            last_active=device.last_active,
            is_current=device.id == current_device_id,
            trusted=device.trusted,
        )
        for device in devices
    ]


@router.patch("/me/devices/{device_id}/trust")
async def update_device_trust(
    device_id: str,
    payload: DeviceTrustUpdateRequest,
    current: tuple[str, str] = Depends(get_current_device),
    db: AsyncSession = Depends(get_db),
):
    """Change account device trust from an already trusted session."""
    user_id, current_device_id = current
    target = await db.get(Device, device_id)
    if target is None or target.user_id != user_id:
        raise HTTPException(status_code=404, detail="Device not found")
    if target.id == current_device_id and not payload.trusted:
        raise HTTPException(status_code=400, detail="Cannot distrust current device")
    target_id = target.id
    target.trusted = payload.trusted
    await db.commit()
    if not payload.trusted:
        await manager.revoke_device(target_id)
    return {"ok": True, "device_id": target_id, "trusted": payload.trusted}


@router.delete("/me/devices/others")
async def revoke_other_devices(
    current: tuple[str, str] = Depends(get_current_device),
    db: AsyncSession = Depends(get_db),
):
    """Remove every device record except the caller's."""
    user_id, current_device_id = current
    revoked_devices = (
        await db.execute(
            select(Device).where(
                Device.user_id == user_id,
                Device.id != current_device_id,
            )
        )
    ).scalars().all()
    revoked_ids = [device.id for device in revoked_devices]
    for device in revoked_devices:
        await append_key_event(
            db,
            user_id=user_id,
            device_id=device.id,
            event_type="device_revoked",
            identity_key_bundle=device.identity_key_bundle,
            commit=False,
        )
        await db.delete(device)
    await db.commit()
    for device_id in revoked_ids:
        await manager.revoke_device(device_id)
    return {"ok": True, "revoked": len(revoked_ids)}


@router.delete("/me/devices/{device_id}")
async def revoke_device(
    device_id: str,
    current: tuple[str, str] = Depends(get_current_device),
    db: AsyncSession = Depends(get_db),
):
    """Revoke a single device session (not the caller's)."""
    user_id, current_device_id = current
    if device_id == current_device_id:
        raise HTTPException(status_code=400, detail="Cannot revoke current device")
    device = await db.get(Device, device_id)
    if device is None or device.user_id != user_id:
        raise HTTPException(status_code=404, detail="Device not found")
    await append_key_event(
        db,
        user_id=user_id,
        device_id=device_id,
        event_type="device_revoked",
        identity_key_bundle=device.identity_key_bundle,
        commit=False,
    )
    await db.delete(device)
    await db.commit()
    await manager.revoke_device(device_id)
    return {"ok": True}


@router.get("/{user_id}/devices")
async def get_user_devices(
    user_id: str,
    exclude_device_id: str | None = Query(default=None),
    current: tuple[str, str] = Depends(get_current_device),
    db: AsyncSession = Depends(get_db),
):
    """Return trusted device identity keys for per-device E2EE."""
    query = select(Device).where(
        Device.user_id == user_id,
        Device.trusted.is_(True),
    )
    if exclude_device_id:
        query = query.where(Device.id != exclude_device_id)
    devices = (await db.execute(query)).scalars().all()
    result = []
    for device in devices:
        bundle = device.identity_key_bundle
        identity_key = (
            bundle.get("identity_key") if isinstance(bundle, dict) else None
        )
        result.append(
            {
                "device_id": device.id,
                "device_name": device.device_name,
                "device_type": device.device_type,
                "identity_key": identity_key,
            }
        )
    return result

