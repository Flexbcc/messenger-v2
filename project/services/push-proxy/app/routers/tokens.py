"""
Token registration endpoints.

POST /tokens      — клиент регистрирует/обновляет push token после логина
DELETE /tokens    — клиент удаляет token при logout/revoke device
"""
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, Header, HTTPException
from pydantic import BaseModel

from app.auth import verify_client_token
from app.db import get_db

router = APIRouter(prefix="/tokens", tags=["tokens"])


class RegisterTokenRequest(BaseModel):
    device_id: str
    platform: str   # "fcm" | "apns" | "webpush"
    token: str


@router.post("", status_code=204)
async def register_token(
    payload: RegisterTokenRequest,
    user_id: str = Depends(verify_client_token),
    db=Depends(get_db),
):
    """
    Клиент вызывает при каждом старте приложения и при получении нового токена
    от FCM/APNs. Upsert — обновляет существующую запись.
    """
    if payload.platform not in ("fcm", "apns", "webpush"):
        raise HTTPException(status_code=400, detail="unsupported push platform")

    now = datetime.now(timezone.utc).isoformat()
    await db.execute("""
        INSERT INTO push_tokens (user_id, device_id, platform, token, updated_at)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(user_id, device_id) DO UPDATE
        SET platform=excluded.platform, token=excluded.token, updated_at=excluded.updated_at
    """, (user_id, payload.device_id, payload.platform, payload.token, now))
    await db.commit()


@router.delete("/{device_id}", status_code=204)
async def delete_token(
    device_id: str,
    user_id: str = Depends(verify_client_token),
    db=Depends(get_db),
):
    """Клиент вызывает при logout или revoke device."""
    await db.execute(
        "DELETE FROM push_tokens WHERE user_id=? AND device_id=?",
        (user_id, device_id),
    )
    await db.commit()
