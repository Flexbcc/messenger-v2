from datetime import datetime, timezone

from fastapi import Depends, HTTPException, Header
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import get_db
from app.models import Device
from app.security import verify_token


async def get_current_device(
    authorization: str = Header(...),
    db: AsyncSession = Depends(get_db),
) -> tuple[str, str]:
    """Returns (user_id, device_id) from a 'Bearer <jwt>' Authorization header."""
    if not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="Missing bearer token")
    token = authorization.removeprefix("Bearer ")
    payload = verify_token(token)
    if not payload:
        raise HTTPException(status_code=401, detail="Invalid or expired token")

    device_id = payload["device_id"]
    device = await db.get(Device, device_id)
    if device:
        device.last_active = datetime.now(timezone.utc).replace(tzinfo=None)
        await db.commit()

    return payload["sub"], device_id
