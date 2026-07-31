"""One-time symmetric device linking via a QR payload."""
import base64
import hashlib
import json
import os
import uuid
from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field
from sqlalchemy import select, text
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import get_db
from app.deps import get_current_device
from app.key_transparency import append_key_event
from app.models import Device, User
from app.security import create_access_token

router = APIRouter(prefix="/auth/device-links", tags=["auth"])
LINK_TTL = timedelta(minutes=5)


class CreateDeviceLinkRequest(BaseModel):
    device_name: str = Field(min_length=1, max_length=100)
    device_type: str = Field(min_length=1, max_length=20)
    auth_public_key: str
    identity_key_bundle: dict


class DeviceLinkSecretRequest(BaseModel):
    secret: str


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _hash_secret(secret: str) -> str:
    return hashlib.sha256(secret.encode()).hexdigest()


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
    await _ensure_table(db)
    row = (
        await db.execute(
            text("SELECT * FROM device_link_requests WHERE id = :id"),
            {"id": link_id},
        )
    ).mappings().fetchone()
    if not row or row["secret_hash"] != _hash_secret(secret):
        raise HTTPException(status_code=404, detail="Device link not found")
    if datetime.fromisoformat(row["expires_at"]) < _now():
        raise HTTPException(status_code=410, detail="Device link expired")
    return row


@router.post("")
async def create_device_link(
    payload: CreateDeviceLinkRequest,
    db: AsyncSession = Depends(get_db),
):
    try:
        if len(base64.b64decode(payload.auth_public_key, validate=True)) != 32:
            raise ValueError
    except (ValueError, TypeError):
        raise HTTPException(status_code=400, detail="Invalid Ed25519 public key")

    await _ensure_table(db)
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
            "identity_key_bundle": json.dumps(payload.identity_key_bundle),
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
    current: tuple[str, str] = Depends(get_current_device),
    db: AsyncSession = Depends(get_db),
):
    user_id, approving_device_id = current
    approving_device = await db.get(Device, approving_device_id)
    if not approving_device or approving_device.user_id != user_id:
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
    )
    if existing is None:
        db.add(device)
        await db.flush()
        await append_key_event(
            db,
            user_id=user_id,
            device_id=device.id,
            event_type="device_registered",
            identity_key_bundle=device.identity_key_bundle,
        )

    access_token = create_access_token({"sub": user_id, "device_id": device.id})
    await db.execute(
        text("""
            UPDATE device_link_requests
            SET status = 'approved', user_id = :user_id, device_id = :device_id,
                access_token = :access_token
            WHERE id = :id
        """),
        {
            "id": link_id,
            "user_id": user_id,
            "device_id": device.id,
            "access_token": access_token,
        },
    )
    await db.commit()
    return {"status": "approved", "device_id": device.id}


@router.post("/{link_id}/inspect")
async def inspect_device_link(
    link_id: str,
    payload: DeviceLinkSecretRequest,
    current: tuple[str, str] = Depends(get_current_device),
    db: AsyncSession = Depends(get_db),
):
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
    db: AsyncSession = Depends(get_db),
):
    row = await _load_request(db, link_id, payload.secret)
    if row["status"] == "pending":
        return {"status": "pending", "expires_at": row["expires_at"]}
    if row["status"] != "approved" or not row["access_token"]:
        raise HTTPException(status_code=409, detail="Device link denied")
    response = {
        "status": "approved",
        "user_id": row["user_id"],
        "device_id": row["device_id"],
        "access_token": row["access_token"],
    }
    user = await db.get(User, row["user_id"])
    response["display_name"] = user.display_name if user else "OUO"
    await db.execute(
        text("DELETE FROM device_link_requests WHERE id = :id"),
        {"id": link_id},
    )
    await db.commit()
    return response
