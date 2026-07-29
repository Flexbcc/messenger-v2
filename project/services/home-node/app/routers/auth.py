"""
Registration + login. Two paths coexist (see ADR-0007):
- Ed25519 challenge-response, per-device (spec/0300_CRYPTO.md) — target model.
- identifier (phone/login/email) + password — temporary bridge.
"""
import base64
import os
from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, Depends, Header, HTTPException
from sqlalchemy import delete as sa_delete, or_, select, text
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import settings
from app.db import get_db
from app.discovery_publish import republish_user_to_discovery
from app.profile_helpers import normalize_login
from app.key_transparency import append_key_event
from app.models import Device, User
from app.pow import issue_challenge, pow_enabled, verify_pow
from app.deps import get_current_device
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
from app.security import create_access_token, hash_password, revoke_token, verify_ed25519_signature, verify_password, verify_token

router = APIRouter(prefix="/auth", tags=["auth"])


# ---------------------------------------------------------------------------
# SQLite-backed challenge store
# Таблица auth_challenges создаётся при первом /challenge запросе через
# db.run_sync (sync SQLite), т.к. структура простейшая и не требует Alembic.
# ---------------------------------------------------------------------------

async def _ensure_challenge_table(db: AsyncSession) -> None:
    await db.execute(text("""
        CREATE TABLE IF NOT EXISTS auth_challenges (
            device_id TEXT PRIMARY KEY,
            nonce_b64 TEXT NOT NULL,
            expires_at TEXT NOT NULL
        )
    """))
    await db.commit()


async def _store_challenge(db: AsyncSession, device_id: str, nonce: bytes, expires_at: datetime) -> None:
    await _ensure_challenge_table(db)
    await db.execute(text("""
        INSERT INTO auth_challenges (device_id, nonce_b64, expires_at)
        VALUES (:device_id, :nonce_b64, :expires_at)
        ON CONFLICT(device_id) DO UPDATE SET nonce_b64=excluded.nonce_b64, expires_at=excluded.expires_at
    """), {"device_id": device_id, "nonce_b64": base64.b64encode(nonce).decode(), "expires_at": expires_at.isoformat()})
    await db.commit()


async def _pop_challenge(db: AsyncSession, device_id: str) -> tuple[bytes, datetime] | None:
    """Возвращает (nonce, expires_at) и удаляет запись (one-time use)."""
    await _ensure_challenge_table(db)
    # Сначала чистим протухшие
    await db.execute(text("DELETE FROM auth_challenges WHERE expires_at < :now"),
                     {"now": datetime.now(timezone.utc).isoformat()})
    row = (await db.execute(
        text("SELECT nonce_b64, expires_at FROM auth_challenges WHERE device_id = :d"),
        {"d": device_id},
    )).fetchone()
    if not row:
        return None
    await db.execute(text("DELETE FROM auth_challenges WHERE device_id = :d"), {"d": device_id})
    await db.commit()
    nonce = base64.b64decode(row[0])
    expires_at = datetime.fromisoformat(row[1])
    if not expires_at.tzinfo:
        expires_at = expires_at.replace(tzinfo=timezone.utc)
    return nonce, expires_at


@router.get("/pow-challenge")
async def get_pow_challenge():
    """Anti-spam PoW (Task #69): выдать challenge для регистрации.

    Клиент должен найти nonce такой что sha256(challenge + ':' + nonce)
    начинается с `difficulty` нулей (hex). Challenge одноразовый, TTL 5 минут.
    Если difficulty=0 — PoW отключён, регистрация без challenge.
    """
    return issue_challenge()


@router.post("/register", response_model=RegisterResponse)
async def register(payload: RegisterRequest, db: AsyncSession = Depends(get_db)):
    # Anti-spam PoW (Task #69): проверяем решение перед любой работой с БД
    if pow_enabled():
        err = verify_pow(payload.pow_challenge or "", payload.pow_nonce or "")
        if err:
            raise HTTPException(status_code=400, detail=f"PoW verification failed: {err}")

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

    login = None
    if payload.login:
        try:
            login = normalize_login(payload.login)
        except ValueError as e:
            raise HTTPException(status_code=400, detail=str(e)) from e

    user = User(
        display_name=payload.display_name,
        phone=payload.phone,
        login=login,
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

    # Key Transparency Log (Task #67): регистрация первого устройства
    await append_key_event(
        db,
        user_id=user.id,
        device_id=device.id,
        event_type="device_registered",
        identity_key_bundle=payload.identity_key_bundle,
    )

    await republish_user_to_discovery(db, user, device)

    access_token = create_access_token({"sub": user.id, "device_id": device.id})
    return RegisterResponse(user_id=user.id, device_id=device.id, access_token=access_token)


@router.post("/challenge", response_model=ChallengeResponse)
async def challenge(payload: ChallengeRequest, db: AsyncSession = Depends(get_db)):
    device = await db.get(Device, payload.device_id)
    if not device:
        raise HTTPException(status_code=404, detail="Unknown device_id")

    nonce = os.urandom(32)
    expires_at = datetime.now(timezone.utc) + timedelta(seconds=settings.challenge_ttl_seconds)
    await _store_challenge(db, payload.device_id, nonce, expires_at)

    return ChallengeResponse(nonce=base64.b64encode(nonce).decode(), expires_at=expires_at.isoformat())


@router.post("/verify", response_model=VerifyResponse)
async def verify(payload: VerifyRequest, db: AsyncSession = Depends(get_db)):
    device = await db.get(Device, payload.device_id)
    if not device:
        raise HTTPException(status_code=404, detail="Unknown device_id")

    pending = await _pop_challenge(db, payload.device_id)
    if not pending:
        raise HTTPException(status_code=400, detail="No pending challenge — call /auth/challenge first")

    nonce, expires_at = pending
    if datetime.now(timezone.utc) > expires_at:
        raise HTTPException(status_code=400, detail="Challenge expired")

    if base64.b64decode(payload.nonce) != nonce:
        raise HTTPException(status_code=400, detail="Nonce mismatch")

    if not verify_ed25519_signature(device.auth_public_key, nonce, payload.signature):
        raise HTTPException(status_code=401, detail="Invalid signature")

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
    _is_new_device = device is None
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

    # Key Transparency Log (Task #67): новое устройство при логине
    if _is_new_device:
        await append_key_event(
            db,
            user_id=user.id,
            device_id=device.id,
            event_type="device_registered",
            identity_key_bundle=payload.identity_key_bundle,
        )

    await republish_user_to_discovery(db, user, device)

    access_token = create_access_token({"sub": user.id, "device_id": device.id})
    return LoginResponse(user_id=user.id, device_id=device.id, access_token=access_token)


@router.post("/logout", status_code=204)
async def logout(
    authorization: str = Header(...),
    db: AsyncSession = Depends(get_db),
    _current: tuple = Depends(get_current_device),
):
    """
    Инвалидирует текущий JWT немедленно путём записи jti в revoked_tokens.
    После logout токен отклоняется при любом запросе к get_current_device.
    """
    token = authorization.removeprefix("Bearer ")
    payload = verify_token(token)
    if payload and payload.get("jti"):
        # exp хранится как Unix timestamp
        from datetime import timezone as _tz
        exp_ts = payload.get("exp", 0)
        expires_at = datetime.fromtimestamp(exp_ts, tz=_tz.utc)
        await revoke_token(db, payload["jti"], expires_at)
