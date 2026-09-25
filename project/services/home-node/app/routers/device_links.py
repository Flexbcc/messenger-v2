"""One-time symmetric device linking via a QR payload."""
import base64
import hashlib
import hmac
import json
import os
import uuid
from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel, Field
from nacl.exceptions import CryptoError
from nacl.secret import SecretBox
from sqlalchemy import select, text
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import get_db
from app.deps import get_current_device
from app.key_transparency import append_key_event
from app.models import Device, User
from app.schemas import IdentityKeyBundle
from app.security import create_access_token
from shared.security.metrics import RateLimiter

router = APIRouter(prefix="/auth/device-links", tags=["auth"])
LINK_TTL = timedelta(minutes=5)
MAX_PENDING_LINKS = 10_000
_LINK_SECRET_PATTERN = r"^[A-Za-z0-9_-]{43}$"
_create_limiter = RateLimiter(
    rate=0.05,
    capacity=5.0,
    max_buckets=20_000,
    idle_ttl_seconds=1800.0,
)
_access_limiter = RateLimiter(
    rate=0.5,
    capacity=10.0,
    max_buckets=40_000,
    idle_ttl_seconds=900.0,
)


class CreateDeviceLinkRequest(BaseModel):
    model_config = {"extra": "forbid"}
    device_name: str = Field(min_length=1, max_length=100)
    device_type: str = Field(min_length=1, max_length=20)
    auth_public_key: str = Field(min_length=40, max_length=128)
    identity_key_bundle: IdentityKeyBundle


class DeviceLinkSecretRequest(BaseModel):
    model_config = {"extra": "forbid"}
    secret: str = Field(
        min_length=43,
        max_length=43,
        pattern=_LINK_SECRET_PATTERN,
    )


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _hash_secret(secret: str) -> str:
    return hashlib.sha256(secret.encode()).hexdigest()


def _token_box(secret: str) -> SecretBox:
    key = hashlib.sha256(
        b"ouo-device-link-access-token-v1\x00" + secret.encode("ascii")
    ).digest()
    return SecretBox(key)


def _seal_access_token(access_token: str, secret: str) -> str:
    encrypted = _token_box(secret).encrypt(access_token.encode("utf-8"))
    return base64.urlsafe_b64encode(bytes(encrypted)).decode("ascii")


def _open_access_token(ciphertext: str, secret: str) -> str:
    try:
        encrypted = base64.b64decode(ciphertext, altchars=b"-_", validate=True)
        return _token_box(secret).decrypt(encrypted).decode("utf-8")
    except (ValueError, UnicodeDecodeError, CryptoError) as exc:
        raise HTTPException(
            status_code=500,
            detail="Stored device link credential is invalid",
        ) from exc


def _client_host(request: Request) -> str:
    # Deliberately use the ASGI peer address. Forwarded headers are only safe
    # when interpreted by a separately configured trusted-proxy middleware.
    return request.client.host if request.client else "unknown"


def _validated_link_id(link_id: str) -> str:
    try:
        parsed = uuid.UUID(link_id)
    except (ValueError, AttributeError):
        raise HTTPException(status_code=404, detail="Device link not found")
    if parsed.version != 4 or str(parsed) != link_id:
        raise HTTPException(status_code=404, detail="Device link not found")
    return link_id


def _limit_access(request: Request, link_id: str, operation: str) -> None:
    host = _client_host(request)
    if not _access_limiter.allow(f"{operation}:ip:{host}"):
        raise HTTPException(status_code=429, detail="Device link rate limit exceeded")
    if not _access_limiter.allow(f"{operation}:link:{link_id}"):
        raise HTTPException(status_code=429, detail="Device link rate limit exceeded")


async def _ensure_table(db: AsyncSession) -> None:
    await db.execute(text("""
        CREATE TABLE IF NOT EXISTS device_link_requests (
            id TEXT PRIMARY KEY,
            secret_hash TEXT NOT NULL,
            device_name TEXT NOT NULL,
            device_type TEXT NOT NULL,
            auth_public_key TEXT NOT NULL,
            identity_key_bundle TEXT NOT NULL,
            status TEXT NOT NULL,
            user_id TEXT,
            device_id TEXT,
            access_token TEXT,
            created_at TEXT NOT NULL,
            expires_at TEXT NOT NULL
        )
    """))
    await db.execute(
        text("DELETE FROM device_link_requests WHERE expires_at < :now"),
        {"now": _now().isoformat()},
    )
    await db.commit()


async def _load_request(db: AsyncSession, link_id: str, secret: str):
    link_id = _validated_link_id(link_id)
    await _ensure_table(db)
    row = (
        await db.execute(
            text("SELECT * FROM device_link_requests WHERE id = :id"),
            {"id": link_id},
        )
    ).mappings().fetchone()
    if not row or not hmac.compare_digest(row["secret_hash"], _hash_secret(secret)):
        raise HTTPException(status_code=404, detail="Device link not found")
    if datetime.fromisoformat(row["expires_at"]) < _now():
        raise HTTPException(status_code=410, detail="Device link expired")
    return row


@router.post("")
async def create_device_link(
    payload: CreateDeviceLinkRequest,
    request: Request,
    db: AsyncSession = Depends(get_db),
):
    if not _create_limiter.allow(f"create:{_client_host(request)}"):
        raise HTTPException(status_code=429, detail="Device link creation rate limit exceeded")
    try:
        if len(base64.b64decode(payload.auth_public_key, validate=True)) != 32:
            raise ValueError
    except (ValueError, TypeError):
        raise HTTPException(status_code=400, detail="Invalid Ed25519 public key")

    await _ensure_table(db)
    pending_count = await db.scalar(
        text("SELECT COUNT(*) FROM device_link_requests WHERE status = 'pending'")
    )
    if pending_count is None or pending_count >= MAX_PENDING_LINKS:
        raise HTTPException(status_code=503, detail="Device link capacity exceeded")
    link_id = str(uuid.uuid4())
    secret = base64.urlsafe_b64encode(os.urandom(32)).decode().rstrip("=")
    expires_at = _now() + LINK_TTL
    await db.execute(
        text("""
            INSERT INTO device_link_requests (
                id, secret_hash, device_name, device_type, auth_public_key,
                identity_key_bundle, status, created_at, expires_at
            ) VALUES (
                :id, :secret_hash, :device_name, :device_type, :auth_public_key,
                :identity_key_bundle, 'pending', :created_at, :expires_at
            )
        """),
        {
            "id": link_id,
            "secret_hash": _hash_secret(secret),
            "device_name": payload.device_name,
            "device_type": payload.device_type,
            "auth_public_key": payload.auth_public_key,
            "identity_key_bundle": json.dumps(
                payload.identity_key_bundle.model_dump(),
                separators=(",", ":"),
            ),
            "created_at": _now().isoformat(),
            "expires_at": expires_at.isoformat(),
        },
    )
    await db.commit()
    qr_payload = json.dumps(
        {"kind": "ouo_device_link", "v": 1, "id": link_id, "secret": secret},
        separators=(",", ":"),
    )
    return {
        "link_id": link_id,
        "secret": secret,
        "qr_payload": qr_payload,
        "expires_at": expires_at.isoformat(),
    }


@router.post("/{link_id}/approve")
async def approve_device_link(
    link_id: str,
    payload: DeviceLinkSecretRequest,
    request: Request,
    current: tuple[str, str] = Depends(get_current_device),
    db: AsyncSession = Depends(get_db),
):
    link_id = _validated_link_id(link_id)
    _limit_access(request, link_id, "approve")
    user_id, approving_device_id = current
    approving_device = await db.get(Device, approving_device_id)
    if (
        not approving_device
        or approving_device.user_id != user_id
        or not approving_device.trusted
    ):
        raise HTTPException(status_code=403, detail="Trusted device required")
    row = await _load_request(db, link_id, payload.secret)
    if row["status"] != "pending":
        raise HTTPException(status_code=409, detail="Device link already handled")

    existing = (
        await db.execute(
            select(Device).where(
                Device.user_id == user_id,
                Device.auth_public_key == row["auth_public_key"],
            )
        )
    ).scalar_one_or_none()
    device = existing or Device(
        user_id=user_id,
        device_name=row["device_name"],
        device_type=row["device_type"],
        auth_public_key=row["auth_public_key"],
        identity_key_bundle=json.loads(row["identity_key_bundle"]),
        trusted=True,
    )
    if existing is not None:
        existing.trusted = True
    if existing is None:
        db.add(device)
        await db.flush()
        await append_key_event(
            db,
            user_id=user_id,
            device_id=device.id,
            event_type="device_registered",
            identity_key_bundle=device.identity_key_bundle,
            commit=False,
        )

    access_token = create_access_token({"sub": user_id, "device_id": device.id})
    sealed_access_token = _seal_access_token(access_token, payload.secret)
    claimed = await db.execute(
        text("""
            UPDATE device_link_requests
            SET status = 'approved', user_id = :user_id, device_id = :device_id,
                access_token = :access_token
            WHERE id = :id AND status = 'pending'
        """),
        {
            "id": link_id,
            "user_id": user_id,
            "device_id": device.id,
            "access_token": sealed_access_token,
        },
    )
    if claimed.rowcount != 1:
        await db.rollback()
        raise HTTPException(status_code=409, detail="Device link already handled")
    await db.commit()
    return {"status": "approved", "device_id": device.id}


@router.post("/{link_id}/inspect")
async def inspect_device_link(
    link_id: str,
    payload: DeviceLinkSecretRequest,
    request: Request,
    current: tuple[str, str] = Depends(get_current_device),
    db: AsyncSession = Depends(get_db),
):
    link_id = _validated_link_id(link_id)
    _limit_access(request, link_id, "inspect")
    user_id, approving_device_id = current
    approving_device = await db.get(Device, approving_device_id)
    if not approving_device or approving_device.user_id != user_id:
        raise HTTPException(status_code=403, detail="Trusted device required")
    row = await _load_request(db, link_id, payload.secret)
    return {
        "status": row["status"],
        "device_name": row["device_name"],
        "device_type": row["device_type"],
        "expires_at": row["expires_at"],
    }


@router.post("/{link_id}/poll")
async def poll_device_link(
    link_id: str,
    payload: DeviceLinkSecretRequest,
    request: Request,
    db: AsyncSession = Depends(get_db),
):
    link_id = _validated_link_id(link_id)
    _limit_access(request, link_id, "poll")
    row = await _load_request(db, link_id, payload.secret)
    if row["status"] == "pending":
        return {"status": "pending", "expires_at": row["expires_at"]}
    if row["status"] != "approved" or not row["access_token"]:
        raise HTTPException(status_code=409, detail="Device link denied")
    access_token = _open_access_token(row["access_token"], payload.secret)
    # Claim and delete in one statement so concurrent poll requests cannot
    # receive the same bearer token twice.
    consumed = (
        await db.execute(
            text("""
                DELETE FROM device_link_requests
                WHERE id = :id AND secret_hash = :secret_hash
                  AND status = 'approved' AND expires_at >= :now
                RETURNING user_id, device_id, access_token
            """),
            {
                "id": link_id,
                "secret_hash": _hash_secret(payload.secret),
                "now": _now().isoformat(),
            },
        )
    ).mappings().fetchone()
    if consumed is None:
        await db.rollback()
        raise HTTPException(status_code=409, detail="Device link token already consumed")
    await db.commit()
    response = {
        "status": "approved",
        "user_id": consumed["user_id"],
        "device_id": consumed["device_id"],
        "access_token": access_token,
    }
    user = await db.get(User, consumed["user_id"])
    response["display_name"] = user.display_name if user else "OUO"
    return response
