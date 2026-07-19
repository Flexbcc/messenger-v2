"""Authenticated storage-app pairing for logged-in users."""
from __future__ import annotations

from typing import Any

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import get_db
from app.deps import get_current_device
from app.storage_pairing_service import pair_user_with_storage_app
from shared.storage.personal_pc_pairing import PairingPayloadError

me_router = APIRouter(prefix="/users/me/storage", tags=["storage"])


class PersonalPcPairMeBody(BaseModel):
    payload: str | dict[str, Any] = Field(
        ...,
        description="QR JSON (kind ouo_ppc_pair) or raw string",
    )


@me_router.post("/personal-pc/pair")
async def post_personal_pc_pair_me(
    body: PersonalPcPairMeBody,
    current: tuple[str, str] = Depends(get_current_device),
    db: AsyncSession = Depends(get_db),
):
    """Pair the authenticated user's storage profile with storage-app via QR."""
    user_id, _device_id = current
    try:
        return await pair_user_with_storage_app(db, user_id, body.payload)
    except PairingPayloadError as e:
        raise HTTPException(status_code=400, detail=str(e)) from e
