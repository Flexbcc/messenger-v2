"""
Registration + login. Two paths coexist (see ADR-0007):
- Ed25519 challenge-response, per-device (spec/0300_CRYPTO.md) — target model.
- identifier (phone/login/email) + password — temporary bridge.
"""
import base64
import os
from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import settings
from app.db import get_db
from app.federation import publish_user_to_discovery
from app.models import Device, User
from app.schemas import (
    ChallengeRequest,
    ChallengeResponse,
    LoginRequest,
    LoginResponse,
    RegisterRequest,
    RegisterResponse,
    VerifyRequest,
    VerifyResponse,
)
from app.security import create_access_token, hash_password, verify_ed25519_signature, verify_password

router = APIRouter(prefix="/auth", tags=["auth"])

# In-memory challenge store (single-instance MVP; see spec/0009_DEVOPS notes
# on Stateless Communication — a real deployment would use a shared cache).
_pending_challenges: dict[str, tuple[bytes, datetime]] = {}


@router.post("/register", response_model=RegisterResponse)
async def register(payload: RegisterRequest, db: AsyncSession = Depends(get_db)):
    existing = await db.execute(
        select(User).where(
            or_(
                User.phone == payload.phone,
                User.login == payload.login if payload.login else False,
                User.email == payload.email if payload.email else False,
            )
        )
    )
    if existing.scalar_one_or_none():
        raise HTTPException(status_code=400, detail="phone/login/email already registered")

    user = User(
        display_name=payload.display_name,
        phone=payload.phone,
        login=payload.login,
        email=payload.email,
        password_hash=hash_password(payload.password),
    )
    db.add(user)
    await db.flush()

    device = Device(
        user_id=user.id,
        device_name=payload.device_name,
        device_type=payload.device_type,
        auth_public_key=payload.auth_public_key,
        identity_key_bundle=payload.identity_key_bundle,
    )
    db.add(device)
    await db.commit()

    await publish_user_to_discovery(user.id, user.display_name, device.auth_public_key)

    access_token = create_access_token({"sub": user.id, "device_id": device.id})
    return RegisterResponse(user_id=user.id, device_id=device.id, access_token=access_token)


@router.post("/challenge", response_model=ChallengeResponse)
async def challenge(payload: ChallengeRequest, db: AsyncSession = Depends(get_db)):
    device = await db.get(Device, payload.device_id)
    if not device:
        raise HTTPException(status_code=404, detail="Unknown device_id")

    nonce = os.urandom(32)
    expires_at = datetime.now(timezone.utc) + timedelta(seconds=settings.challenge_ttl_seconds)
    _pending_challenges[payload.device_id] = (nonce, expires_at)

    return ChallengeResponse(nonce=base64.b64encode(nonce).decode(), expires_at=expires_at.isoformat())


@router.post("/verify", response_model=VerifyResponse)
async def verify(payload: VerifyRequest, db: AsyncSession = Depends(get_db)):
    device = await db.get(Device, payload.device_id)
    if not device:
        raise HTTPException(status_code=404, detail="Unknown device_id")

    pending = _pending_challenges.get(payload.device_id)
    if not pending:
        raise HTTPException(status_code=400, detail="No pending challenge — call /auth/challenge first")

    nonce, expires_at = pending
    if datetime.now(timezone.utc) > expires_at:
        del _pending_challenges[payload.device_id]
        raise HTTPException(status_code=400, detail="Challenge expired")

    if base64.b64decode(payload.nonce) != nonce:
        raise HTTPException(status_code=400, detail="Nonce mismatch")

    if not verify_ed25519_signature(device.auth_public_key, nonce, payload.signature):
        raise HTTPException(status_code=401, detail="Invalid signature")

    del _pending_challenges[payload.device_id]  # one-time use

    access_token = create_access_token({"sub": device.user_id, "device_id": device.id})
    return VerifyResponse(access_token=access_token, user_id=device.user_id, device_id=device.id)


@router.post("/login", response_model=LoginResponse)
async def login(payload: LoginRequest, db: AsyncSession = Depends(get_db)):
    """Temporary bridge login by identifier+password — see ADR-0007."""
    result = await db.execute(
        select(User).where(
            or_(User.phone == payload.identifier, User.login == payload.identifier, User.email == payload.identifier)
        )
    )
    user = result.scalar_one_or_none()
    if not user or not verify_password(payload.password, user.password_hash):
        raise HTTPException(status_code=401, detail="Invalid identifier or password")

    existing_device = await db.execute(
        select(Device).where(Device.user_id == user.id, Device.auth_public_key == payload.auth_public_key)
    )
    device = existing_device.scalar_one_or_none()
    if not device:
        device = Device(
            user_id=user.id,
            device_name=payload.device_name,
            device_type=payload.device_type,
            auth_public_key=payload.auth_public_key,
            identity_key_bundle=payload.identity_key_bundle,
        )
        db.add(device)
        await db.commit()

    access_token = create_access_token({"sub": user.id, "device_id": device.id})
    return LoginResponse(user_id=user.id, device_id=device.id, access_token=access_token)
