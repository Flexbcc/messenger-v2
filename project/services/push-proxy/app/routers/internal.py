"""Home-node-only Push Proxy management endpoints."""
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel

from app.auth import verify_node_secret
from app.config import settings
from app.db import get_db

router = APIRouter(prefix="/internal", tags=["internal"])


class InternalToken(BaseModel):
    user_id: str
    device_id: str
    platform: str
    token: str


@router.get("/vapid-key")
async def vapid_key(_: None = Depends(verify_node_secret)):
    if not settings.vapid_public_key:
        raise HTTPException(status_code=503, detail="VAPID is not configured")
    return {"public_key": settings.vapid_public_key}


@router.put("/tokens", status_code=204)
async def put_token(
    payload: InternalToken,
    _: None = Depends(verify_node_secret),
    db=Depends(get_db),
):
    if payload.platform not in ("fcm", "apns", "webpush"):
        raise HTTPException(status_code=400, detail="unsupported push platform")
    now = datetime.now(timezone.utc).isoformat()
    await db.execute(
        """INSERT INTO push_tokens (user_id, device_id, platform, token, updated_at)
           VALUES (?, ?, ?, ?, ?)
           ON CONFLICT(user_id, device_id) DO UPDATE
           SET platform=excluded.platform, token=excluded.token, updated_at=excluded.updated_at""",
        (payload.user_id, payload.device_id, payload.platform, payload.token, now),
    )
    await db.commit()


@router.delete("/tokens/{user_id}/{device_id}", status_code=204)
async def delete_token(
    user_id: str,
    device_id: str,
    _: None = Depends(verify_node_secret),
    db=Depends(get_db),
):
    await db.execute(
        "DELETE FROM push_tokens WHERE user_id=? AND device_id=?",
        (user_id, device_id),
    )
    await db.commit()
