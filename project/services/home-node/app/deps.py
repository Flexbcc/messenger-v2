from datetime import datetime, timezone

from fastapi import Depends, HTTPException, Header
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import get_db
from app.models import Device
from app.security import is_token_revoked, verify_token


async def _authenticate_device(
    authorization: str = Header(...),
    db: AsyncSession = Depends(get_db),
    *,
    require_trusted: bool,
) -> tuple[str, str]:
    """Returns (user_id, device_id) from a 'Bearer <jwt>' Authorization header."""
    if not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="Missing bearer token")
    token = authorization.removeprefix("Bearer ")
    payload = verify_token(token)
    if not payload:
        raise HTTPException(status_code=401, detail="Invalid or expired token")

    # Проверяем отзыв по jti (logout делает токен недействительным немедленно)
    jti = payload.get("jti")
    if jti and await is_token_revoked(db, jti):
        raise HTTPException(status_code=401, detail="Token has been revoked (logged out)")

    user_id = payload.get("sub")
    device_id = payload.get("device_id")
    if not isinstance(user_id, str) or not isinstance(device_id, str):
        raise HTTPException(status_code=401, detail="Invalid token claims")
    device = await db.get(Device, device_id)
    if device is None or device.user_id != user_id:
        raise HTTPException(status_code=401, detail="Device session is no longer valid")
    if require_trusted and not device.trusted:
        raise HTTPException(status_code=403, detail="Device approval required")
    device.last_active = datetime.now(timezone.utc).replace(tzinfo=None)
    await db.commit()

    return user_id, device_id


async def get_current_device(
    authorization: str = Header(...),
    db: AsyncSession = Depends(get_db),
) -> tuple[str, str]:
    return await _authenticate_device(
        authorization=authorization,
        db=db,
        require_trusted=True,
    )


async def get_current_device_allow_untrusted(
    authorization: str = Header(...),
    db: AsyncSession = Depends(get_db),
) -> tuple[str, str]:
    """Narrow dependency for approval polling and logout only."""
    return await _authenticate_device(
        authorization=authorization,
        db=db,
        require_trusted=False,
    )
