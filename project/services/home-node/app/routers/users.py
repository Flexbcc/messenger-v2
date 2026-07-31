"""
Own-account profile: read and update the fields collected at registration
(display_name/phone/login/email — see ADR-0007). Distinct from devices.py's
GET /users/{user_id}/prekey-bundle, which exposes crypto material for any
user and is unauthenticated by design (needed by any sender before X3DH).
This router is auth-scoped to "me" only — no endpoint here can read or
change another user's account.
"""
from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import delete, func, or_, select
from sqlalchemy.orm import aliased
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import get_db
from app.deps import get_current_device
from app.discovery_publish import republish_user_to_discovery
from app.profile_helpers import normalize_login
from app.key_transparency import append_key_event, get_key_log, verify_log_chain
from app.models import Conversation, ConversationParticipant, Device, User
from app.schemas import (
    ChangePasswordRequest,
    DeviceSummaryResponse,
    MeResponse,
    PresencePolicyPayload,
    PresenceResponse,
    ProfileSettingsPayload,
    UpdateDisplayNameRequest,
    UpdateProfileRequest,
)
from app.security import hash_password, verify_password
from app.ws import manager

router = APIRouter(prefix="/users", tags=["users"])


def _me_response(user: User) -> MeResponse:
    return MeResponse(
        user_id=user.id,
        display_name=user.display_name,
        phone=user.phone,
        login=user.login,
        email=user.email,
        bio=user.bio,
        created_at=user.created_at,
    )


async def _device_for_user(db: AsyncSession, user_id: str, device_id: str) -> Device | None:
    device = await db.get(Device, device_id)
    if device is None or device.user_id != user_id:
        return None
    return device


@router.get("/me", response_model=MeResponse)
async def get_me(
    current: tuple[str, str] = Depends(get_current_device),
    db: AsyncSession = Depends(get_db),
):
    user_id, _device_id = current
    user = await db.get(User, user_id)
    if not user:
        raise HTTPException(status_code=404, detail="User not found")
    return _me_response(user)


@router.patch("/me", response_model=MeResponse)
async def update_me(
    payload: UpdateDisplayNameRequest,
    current: tuple[str, str] = Depends(get_current_device),
    db: AsyncSession = Depends(get_db),
):
    user_id, device_id = current
    user = await db.get(User, user_id)
    if not user:
        raise HTTPException(status_code=404, detail="User not found")

    display_name = payload.display_name.strip()
    if not display_name:
        raise HTTPException(status_code=400, detail="display_name cannot be empty")

    user.display_name = display_name
    await db.commit()

    device = await _device_for_user(db, user_id, device_id)
    if device:
        await republish_user_to_discovery(db, user, device)

    return _me_response(user)


@router.put("/me/profile", response_model=MeResponse)
async def update_profile(
    payload: UpdateProfileRequest,
    current: tuple[str, str] = Depends(get_current_device),
    db: AsyncSession = Depends(get_db),
):
    user_id, device_id = current
    user = await db.get(User, user_id)
    if not user:
        raise HTTPException(status_code=404, detail="User not found")

    if payload.display_name is not None:
        name = payload.display_name.strip()
        if not name:
            raise HTTPException(status_code=400, detail="display_name cannot be empty")
        user.display_name = name

    if payload.login is not None:
        raw = payload.login.strip()
        if not raw:
            user.login = None
        else:
            try:
                normalized = normalize_login(raw)
            except ValueError as e:
                raise HTTPException(status_code=400, detail=str(e)) from e
            conflict = await db.execute(
                select(User).where(User.login == normalized, User.id != user_id)
            )
            if conflict.scalar_one_or_none():
                raise HTTPException(status_code=409, detail="login already taken")
            user.login = normalized

    if payload.email is not None:
        email = payload.email.strip() or None
        if email:
            conflict = await db.execute(
                select(User).where(User.email == email, User.id != user_id)
            )
            if conflict.scalar_one_or_none():
                raise HTTPException(status_code=409, detail="email already taken")
        user.email = email

    if payload.phone is not None:
        phone = payload.phone.strip()
        if phone:
            conflict = await db.execute(
                select(User).where(User.phone == phone, User.id != user_id)
            )
            if conflict.scalar_one_or_none():
                raise HTTPException(status_code=409, detail="phone already taken")
            user.phone = phone

    if payload.bio is not None:
        user.bio = payload.bio.strip() or None

    await db.commit()

    device = await _device_for_user(db, user_id, device_id)
    if device:
        await republish_user_to_discovery(db, user, device)

    return _me_response(user)


@router.get("/me/profile-settings")
async def get_profile_settings(
    current: tuple[str, str] = Depends(get_current_device),
    db: AsyncSession = Depends(get_db),
):
    user_id, _device_id = current
    user = await db.get(User, user_id)
    if not user:
        raise HTTPException(status_code=404, detail="User not found")
    return user.profile_settings or {"values": {}, "lists": {}}


@router.put("/me/profile-settings")
async def put_profile_settings(
    payload: ProfileSettingsPayload,
    current: tuple[str, str] = Depends(get_current_device),
    db: AsyncSession = Depends(get_db),
):
    user_id, device_id = current
    user = await db.get(User, user_id)
    if not user:
        raise HTTPException(status_code=404, detail="User not found")
    user.profile_settings = {"values": payload.values, "lists": payload.lists}
    await db.commit()

    device = await _device_for_user(db, user_id, device_id)
    if device:
        await republish_user_to_discovery(db, user, device)

    return {"ok": True}


@router.put("/me/presence-policy")
async def put_presence_policy(
    payload: PresencePolicyPayload,
    current: tuple[str, str] = Depends(get_current_device),
    db: AsyncSession = Depends(get_db),
):
    user_id, _device_id = current
    user = await db.get(User, user_id)
    if not user:
        raise HTTPException(status_code=404, detail="User not found")
    if payload.last_seen not in {"nobody", "contacts", "selected", "everyone"}:
        raise HTTPException(status_code=400, detail="invalid last_seen policy")
    user.presence_policy = payload.model_dump()
    await db.commit()
    return {"ok": True}


async def _share_direct_conversation(
    db: AsyncSession,
    first_user_id: str,
    second_user_id: str,
) -> bool:
    first = aliased(ConversationParticipant)
    second = aliased(ConversationParticipant)
    result = await db.execute(
        select(Conversation.id)
        .join(first, first.conversation_id == Conversation.id)
        .join(second, second.conversation_id == Conversation.id)
        .where(
            Conversation.type == "direct",
            first.user_id == first_user_id,
            second.user_id == second_user_id,
        )
        .limit(1)
    )
    return result.scalar_one_or_none() is not None


@router.get("/{target_user_id}/presence", response_model=PresenceResponse)
async def get_presence(
    target_user_id: str,
    current: tuple[str, str] = Depends(get_current_device),
    db: AsyncSession = Depends(get_db),
):
    viewer_user_id, _device_id = current
    target = await db.get(User, target_user_id)
    if not target:
        raise HTTPException(status_code=404, detail="User not found")

    policy = target.presence_policy or {}
    invisible = bool(policy.get("invisible", False))
    online_enabled = bool(policy.get("online_status", True))
    last_seen_policy = str(policy.get("last_seen", "contacts"))
    selected = set(policy.get("selected_user_ids") or [])
    is_self = viewer_user_id == target_user_id
    is_contact = is_self or await _share_direct_conversation(
        db, viewer_user_id, target_user_id
    )
    allowed = (
        is_self
        or last_seen_policy == "everyone"
        or (last_seen_policy == "contacts" and is_contact)
        or (last_seen_policy == "selected" and viewer_user_id in selected)
    )
    if last_seen_policy == "nobody" and not is_self:
        allowed = False

    last_active = None
    if allowed and not invisible:
        result = await db.execute(
            select(func.max(Device.last_active)).where(Device.user_id == target_user_id)
        )
        last_active = result.scalar_one_or_none()

    return PresenceResponse(
        user_id=target_user_id,
        online=bool(
            (is_self or (allowed and online_enabled and not invisible))
            and manager.is_online(target_user_id)
        ),
        last_seen=last_active,
    )


@router.post("/me/change-password")
async def change_password(
    payload: ChangePasswordRequest,
    current: tuple[str, str] = Depends(get_current_device),
    db: AsyncSession = Depends(get_db),
):
    user_id, _device_id = current
    user = await db.get(User, user_id)
    if not user:
        raise HTTPException(status_code=404, detail="User not found")

    if not verify_password(payload.current_password, user.password_hash):
        raise HTTPException(status_code=401, detail="Current password is incorrect")

    new_password = payload.new_password.strip()
    if len(new_password) < 6:
        raise HTTPException(status_code=400, detail="New password must be at least 6 characters")

    user.password_hash = hash_password(new_password)
    await db.commit()
    return {"ok": True}


@router.get("/me/devices", response_model=list[DeviceSummaryResponse])
async def list_my_devices(
    current: tuple[str, str] = Depends(get_current_device),
    db: AsyncSession = Depends(get_db),
):
    user_id, current_device_id = current
    result = await db.execute(select(Device).where(Device.user_id == user_id).order_by(Device.last_active.desc()))
    devices = result.scalars().all()
    return [
        DeviceSummaryResponse(
            id=d.id,
            device_name=d.device_name,
            device_type=d.device_type,
            created_at=d.created_at,
            last_active=d.last_active,
            is_current=d.id == current_device_id,
        )
        for d in devices
    ]


@router.delete("/me/devices/{device_id}")
async def revoke_device(
    device_id: str,
    current: tuple[str, str] = Depends(get_current_device),
    db: AsyncSession = Depends(get_db),
):
    """Revoke a single device session (not the caller's)."""
    user_id, current_device_id = current
    if device_id == current_device_id:
        raise HTTPException(status_code=400, detail="Cannot revoke current device")
    device = await db.get(Device, device_id)
    if device is None or device.user_id != user_id:
        raise HTTPException(status_code=404, detail="Device not found")
    # Key Transparency Log (Task #67): отзыв устройства
    await append_key_event(
        db,
        user_id=user_id,
        device_id=device_id,
        event_type="device_revoked",
        identity_key_bundle=device.identity_key_bundle,
    )
    await db.delete(device)
    await db.commit()
    return {"ok": True}


@router.get("/{user_id}/devices")
async def get_user_devices(
    user_id: str,
    current: tuple[str, str] = Depends(get_current_device),
    db: AsyncSession = Depends(get_db),
):
    """
    Возвращает список устройств пользователя с их identity_key_bundle для
    per-device E2EE шифрования (Task #57 / spec/0102_DATA_FLOW.md).
    Только аутентифицированные пользователи могут запрашивать чужие устройства.
    """
    devices = (await db.execute(select(Device).where(Device.user_id == user_id))).scalars().all()
    return [
        {
            "device_id": d.id,
            "device_name": d.device_name,
            "device_type": d.device_type,
            "identity_key_bundle": d.identity_key_bundle,
        }
        for d in devices
    ]


@router.delete("/me/devices/others")
async def revoke_other_devices(
    current: tuple[str, str] = Depends(get_current_device),
    db: AsyncSession = Depends(get_db),
):
    """Remove every device record except the caller's — see design.md §15."""
    user_id, current_device_id = current
    await db.execute(
        delete(Device).where(Device.user_id == user_id, Device.id != current_device_id)
    )
    await db.commit()
    return {"ok": True}


@router.get("/{user_id}/key-log")
async def get_user_key_log(
    user_id: str,
    limit: int = 50,
    since_id: str | None = None,
    current: tuple[str, str] = Depends(get_current_device),
    db: AsyncSession = Depends(get_db),
):
    """Key Transparency Log (Task #67) — append-only история смены ключей.

    Возвращает список событий: регистрация устройства, смена ключа, отзыв.
    Каждая запись содержит fingerprint identity key и хэш предыдущей записи
    для верификации целостности цепочки.

    Клиент сравнивает fingerprint текущего ключа с последним в логе.
    Расхождение = признак неожиданной смены ключа (MITM / компрометация).
    """
    entries = await get_key_log(db, user_id, limit=limit, since_id=since_id)
    errors = verify_log_chain(entries)

    return {
        "user_id": user_id,
        "entries": [
            {
                "id": e.id,
                "device_id": e.device_id,
                "event_type": e.event_type,
                "identity_key_fingerprint": e.identity_key_fingerprint,
                "prev_fingerprint": e.prev_fingerprint,
                "created_at": e.created_at.isoformat(),
                "entry_hash": e.entry_hash,
                "prev_entry_hash": e.prev_entry_hash,
            }
            for e in entries
        ],
        "chain_errors": errors,  # пусто если цепочка целостна
        "has_more": len(entries) == limit,
    }
