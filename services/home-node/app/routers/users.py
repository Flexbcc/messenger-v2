"""
Own-account profile: read and update the fields collected at registration
(display_name/phone/login/email — see ADR-0007). Distinct from devices.py's
GET /users/{user_id}/prekey-bundle, which exposes crypto material for any
user and is unauthenticated by design (needed by any sender before X3DH).
This router is auth-scoped to "me" only — no endpoint here can read or
change another user's account.
"""
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import delete, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import get_db
from app.deps import get_current_device
from app.models import Device, User
from app.schemas import (
    ChangePasswordRequest,
    DeviceSummaryResponse,
    MeResponse,
    UpdateDisplayNameRequest,
)
from app.security import hash_password, verify_password

router = APIRouter(prefix="/users", tags=["users"])


@router.get("/me", response_model=MeResponse)
async def get_me(
    current: tuple[str, str] = Depends(get_current_device),
    db: AsyncSession = Depends(get_db),
):
    user_id, _device_id = current
    user = await db.get(User, user_id)
    if not user:
        raise HTTPException(status_code=404, detail="User not found")
    return MeResponse(
        user_id=user.id,
        display_name=user.display_name,
        phone=user.phone,
        login=user.login,
        email=user.email,
        created_at=user.created_at,
    )


@router.patch("/me", response_model=MeResponse)
async def update_me(
    payload: UpdateDisplayNameRequest,
    current: tuple[str, str] = Depends(get_current_device),
    db: AsyncSession = Depends(get_db),
):
    user_id, _device_id = current
    user = await db.get(User, user_id)
    if not user:
        raise HTTPException(status_code=404, detail="User not found")

    display_name = payload.display_name.strip()
    if not display_name:
        raise HTTPException(status_code=400, detail="display_name cannot be empty")

    user.display_name = display_name
    await db.commit()

    return MeResponse(
        user_id=user.id,
        display_name=user.display_name,
        phone=user.phone,
        login=user.login,
        email=user.email,
        created_at=user.created_at,
    )


@router.post("/me/change-password")
async def change_password(
    payload: ChangePasswordRequest,
    current: tuple[str, str] = Depends(get_current_device),
    db: AsyncSession = Depends(get_db),
):
    user_id, _device_id = current
    user = await db.get(User, user_id)
    if not user:
        raise HTTPException(status_code=404, detail="User not found")

    if not verify_password(payload.current_password, user.password_hash):
        raise HTTPException(status_code=401, detail="Current password is incorrect")

    new_password = payload.new_password.strip()
    if len(new_password) < 6:
        raise HTTPException(status_code=400, detail="New password must be at least 6 characters")

    user.password_hash = hash_password(new_password)
    await db.commit()
    return {"ok": True}


@router.get("/me/devices", response_model=list[DeviceSummaryResponse])
async def list_my_devices(
    current: tuple[str, str] = Depends(get_current_device),
    db: AsyncSession = Depends(get_db),
):
    user_id, current_device_id = current
    result = await db.execute(select(Device).where(Device.user_id == user_id).order_by(Device.last_active.desc()))
    devices = result.scalars().all()
    return [
        DeviceSummaryResponse(
            id=d.id,
            device_name=d.device_name,
            device_type=d.device_type,
            created_at=d.created_at,
            last_active=d.last_active,
            is_current=d.id == current_device_id,
        )
        for d in devices
    ]


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
    await db.delete(device)
    await db.commit()
    return {"ok": True}


@router.delete("/me/devices/others")
async def revoke_other_devices(
    current: tuple[str, str] = Depends(get_current_device),
    db: AsyncSession = Depends(get_db),
):
    """Remove every device record except the caller's — see design.md §15."""
    user_id, current_device_id = current
    await db.execute(
        delete(Device).where(Device.user_id == user_id, Device.id != current_device_id)
    )
    await db.commit()
    return {"ok": True}
