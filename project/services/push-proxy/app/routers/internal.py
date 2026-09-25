"""Home-node-only Push Proxy management endpoints."""
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, Path
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator

from app.auth import verify_node_secret
from app.config import settings
from app.db import db_write_lock, get_db
from app.limits import MAX_PUSH_DEVICES_PER_USER
from app.token_crypto import encrypt_push_token
from shared.security.webpush import validate_webpush_subscription_json

router = APIRouter(prefix="/internal", tags=["internal"])


class InternalToken(BaseModel):
    model_config = ConfigDict(extra="forbid")

    user_id: str = Field(
        min_length=1,
        max_length=128,
        pattern=r"^[A-Za-z0-9._:-]+$",
    )
    device_id: str = Field(
        min_length=1,
        max_length=128,
        pattern=r"^[A-Za-z0-9._:-]+$",
    )
    platform: Literal["fcm", "apns", "webpush"]
    token: str = Field(min_length=1, max_length=16_384)

    @field_validator("token")
    @classmethod
    def validate_platform_token(cls, token: str, info) -> str:
        platform = info.data.get("platform")
        if platform == "apns":
            if len(token) != 64 or any(ch not in "0123456789abcdefABCDEF" for ch in token):
                raise ValueError("invalid APNs token")
        elif platform == "fcm":
            if not 20 <= len(token) <= 4096 or any(ch.isspace() or ord(ch) < 0x21 for ch in token):
                raise ValueError("invalid FCM token")
        elif platform == "webpush":
            validate_webpush_subscription_json(token)
        return token


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
    now = datetime.now(timezone.utc).isoformat()
    async with db_write_lock:
        try:
            existing = await db.execute_fetchall(
                "SELECT 1 FROM push_tokens WHERE user_id=? AND device_id=? LIMIT 1",
                (payload.user_id, payload.device_id),
            )
            if not existing:
                count_rows = await db.execute_fetchall(
                    "SELECT COUNT(*) AS count FROM push_tokens WHERE user_id=?",
                    (payload.user_id,),
                )
                if count_rows[0]["count"] >= MAX_PUSH_DEVICES_PER_USER:
                    raise HTTPException(
                        status_code=409,
                        detail="Push device limit reached",
                    )
            await db.execute(
                """INSERT INTO push_tokens (user_id, device_id, platform, token, updated_at)
                   VALUES (?, ?, ?, ?, ?)
                   ON CONFLICT(user_id, device_id) DO UPDATE
                   SET platform=excluded.platform, token=excluded.token, updated_at=excluded.updated_at""",
                (
                    payload.user_id,
                    payload.device_id,
                    payload.platform,
                    encrypt_push_token(payload.token),
                    now,
                ),
            )
            await db.commit()
        except Exception:
            await db.rollback()
            raise


@router.delete("/tokens/{user_id}/{device_id}", status_code=204)
async def delete_token(
    user_id: str = Path(..., min_length=1, max_length=128),
    device_id: str = Path(..., min_length=1, max_length=128),
    _: None = Depends(verify_node_secret),
    db=Depends(get_db),
):
    async with db_write_lock:
        await db.execute(
            "DELETE FROM push_tokens WHERE user_id=? AND device_id=?",
            (user_id, device_id),
        )
        await db.commit()
