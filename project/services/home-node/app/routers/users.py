"""
Own-account profile: read and update the fields collected at registration
(display_name/phone/login/email — see ADR-0007). Distinct from devices.py's
GET /users/{user_id}/prekey-bundle, which exposes crypto material for any
user and is unauthenticated by design (needed by any sender before X3DH).
This router is auth-scoped to "me" only — no endpoint here can read or
change another user's account.
"""
from datetime import timezone
from urllib.parse import urlsplit

from fastapi import APIRouter, Depends, HTTPException, Path, Query
from sqlalchemy import func, or_, select
from sqlalchemy.orm import aliased
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import get_db
from app.config import settings
from app.deps import get_current_device
from app.discovery_publish import republish_user_to_discovery
from app.profile_helpers import normalize_login
from app.key_transparency import get_key_log, verify_log_chain
from app.models import (
    Conversation,
    ConversationParticipant,
    Device,
    KeyTransparencyLog,
    User,
)
from app.schemas import (
    ChangePasswordRequest,
    HomeMigrationExportResponse,
    MeResponse,
    PresencePolicyPayload,
    PresenceResponse,
    ProfileSettingsPayload,
    UpdateDisplayNameRequest,
    UpdateProfileRequest,
    UserIdentityBindingRequest,
    UserIdentityBindingResponse,
)
from app.security import hash_password, verify_password
from app.ws import manager
from shared.security.user_identity_binding import validate_user_identity_binding
from shared.security.home_migration import device_manifest_hash

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


def _home_migration_manifest(user: User, devices: list[Device]) -> dict:
    """Build the exact account state that a destination Home may import.

    Deliberately excluded: password_hash, tokens, messages, conversations,
    private keys, and server-side delivery queues.
    """
    return {
        "manifest_version": 1,
        "user": {
            "user_id": user.id,
            "display_name": user.display_name,
            "phone": user.phone,
            "login": user.login,
            "email": user.email,
            "bio": user.bio,
            "profile_settings": user.profile_settings,
            "presence_policy": user.presence_policy,
            "created_at": user.created_at.replace(tzinfo=timezone.utc).isoformat()
            if user.created_at.tzinfo is None
            else user.created_at.astimezone(timezone.utc).isoformat(),
        },
        "devices": [
            {
                "device_id": device.id,
                "device_name": device.device_name,
                "device_type": device.device_type,
                "auth_public_key": device.auth_public_key,
                "identity_key_bundle": device.identity_key_bundle,
                "trusted": bool(device.trusted),
                "created_at": device.created_at.replace(tzinfo=timezone.utc).isoformat()
                if device.created_at.tzinfo is None
                else device.created_at.astimezone(timezone.utc).isoformat(),
            }
            for device in sorted(devices, key=lambda value: value.id)
        ],
    }


def _valid_migration_destination(value: str) -> bool:
    parsed = urlsplit(value)
    return bool(
        len(value) <= 2048
        and parsed.scheme == "https"
        and parsed.hostname
        and not parsed.username
        and not parsed.password
        and not parsed.query
        and not parsed.fragment
        and (not parsed.path or parsed.path == "/")
    )


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


@router.put("/me/identity-root", response_model=UserIdentityBindingResponse)
async def bind_identity_root(
    payload: UserIdentityBindingRequest,
    current: tuple[str, str] = Depends(get_current_device),
    db: AsyncSession = Depends(get_db),
):
    """Bind a stable Identity Root to this account without exposing its key.

    Both the new Identity Root and the already-authenticated DeviceKey must
    sign the same short-lived object.  Once set, this endpoint is idempotent
    for the same root but cannot replace it; replacement requires the future
    IdentityTransition recovery protocol.
    """
    from datetime import datetime, timezone

    user_id, device_id = current
    user = await db.get(User, user_id)
    device = await _device_for_user(db, user_id, device_id)
    if user is None or device is None:
        raise HTTPException(status_code=404, detail="Account or device not found")
    binding = payload.model_dump()
    minimum_version = user.identity_version or 1
    validation = validate_user_identity_binding(
        binding,
        now=datetime.now(timezone.utc),
        expected_user_id=user_id,
        expected_device_id=device_id,
        expected_device_public_key=device.auth_public_key,
        current_identity_public_key=user.identity_root_public_key,
        minimum_identity_version=minimum_version,
    )
    if not validation.valid:
        raise HTTPException(status_code=400, detail=validation.reason)
    if user.identity_version is not None and payload.identity_version != user.identity_version:
        raise HTTPException(
            status_code=409,
            detail="Identity version change requires IdentityTransition",
        )
    user.identity_root_public_key = payload.identity_public_key
    user.identity_version = payload.identity_version
    user.identity_binding = binding
    await db.commit()
    return UserIdentityBindingResponse(
        user_id=user.id,
        identity_root_public_key=user.identity_root_public_key,
        identity_version=user.identity_version,
        binding_id=payload.binding_id,
    )


@router.get("/me/home-migration/export", response_model=HomeMigrationExportResponse)
async def export_home_migration_manifest(
    to_home: str = Query(..., min_length=8, max_length=2048),
    current: tuple[str, str] = Depends(get_current_device),
    db: AsyncSession = Depends(get_db),
):
    """Export only public account/device material for a new Home.

    The returned hash is what the endpoint signs in its short-lived migration
    ticket.  Export alone changes nothing and grants no access on a new Home.
    """
    if not _valid_migration_destination(to_home):
        raise HTTPException(status_code=400, detail="Destination Home must be an HTTPS origin")
    user_id, _device_id = current
    user = await db.get(User, user_id)
    if user is None:
        raise HTTPException(status_code=404, detail="User not found")
    if not user.identity_root_public_key or not user.identity_binding:
        raise HTTPException(status_code=409, detail="Identity Root binding is required")
    rows = await db.execute(select(Device).where(Device.user_id == user_id))
    devices = list(rows.scalars().all())
    if not devices:
        raise HTTPException(status_code=409, detail="No active devices to migrate")
    manifest = _home_migration_manifest(user, devices)
    return HomeMigrationExportResponse(
        manifest=manifest,
        manifest_hash=device_manifest_hash(manifest),
        identity_binding=user.identity_binding,
        from_home=settings.public_url,
        to_home=to_home.rstrip("/"),
    )


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
    if not settings.password_auth_bridge_enabled:
        raise HTTPException(status_code=404, detail="Password authentication is disabled")
    user_id, _device_id = current
    user = await db.get(User, user_id)
    if not user:
        raise HTTPException(status_code=404, detail="User not found")

    if not verify_password(payload.current_password, user.password_hash):
        raise HTTPException(status_code=401, detail="Current password is incorrect")

    new_password = payload.new_password.strip()
    if len(new_password) < 8:
        raise HTTPException(status_code=400, detail="New password must be at least 8 characters")

    user.password_hash = hash_password(new_password)
    await db.commit()
    return {"ok": True}


@router.get("/{user_id}/key-log")
async def get_user_key_log(
    user_id: str = Path(
        ...,
        pattern=r"^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$",
    ),
    limit: int = Query(50, ge=1, le=200),
    since_id: str | None = Query(
        None,
        pattern=r"^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$",
    ),
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
    try:
        fetched = await get_key_log(
            db,
            user_id,
            limit=limit + 1,
            since_id=since_id,
        )
    except ValueError as exc:
        raise HTTPException(status_code=404, detail="Key log cursor not found") from exc
    has_more = len(fetched) > limit
    entries = fetched[:limit]
    expected_previous_hash = None
    if since_id is not None:
        expected_previous_hash = (
            await db.execute(
                select(KeyTransparencyLog.entry_hash).where(
                    KeyTransparencyLog.id == since_id,
                    KeyTransparencyLog.user_id == user_id,
                )
            )
        ).scalar_one_or_none()
        if expected_previous_hash is None:
            raise HTTPException(status_code=404, detail="Key log cursor not found")
    errors = verify_log_chain(
        entries,
        expected_previous_hash=expected_previous_hash,
    )

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
        "has_more": has_more,
    }
