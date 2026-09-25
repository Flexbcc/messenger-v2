from sqlalchemy import select, delete
from fastapi import APIRouter, Body, Depends, HTTPException
from sqlalchemy.ext.asyncio import AsyncSession
from typing import List, Literal
from pydantic import BaseModel, ConfigDict, Field, field_validator

from app.db import get_db
from app.deps import get_current_device
from app.models import Conversation, ConversationParticipant, User
from app.schemas import ConversationResponse, CreateConversationRequest

router = APIRouter(prefix="/conversations", tags=["conversations"])


class AddMembersRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    user_ids: List[str] = Field(min_length=1, max_length=256)

    @field_validator("user_ids")
    @classmethod
    def validate_user_ids(cls, values: List[str]) -> List[str]:
        if any(not user_id or len(user_id) > 64 for user_id in values):
            raise ValueError("invalid user id")
        if len(values) != len(set(values)):
            raise ValueError("user ids must be unique")
        return values


class GroupMemberRoleRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    role: Literal["admin", "member"]


async def _to_response(db: AsyncSession, conv: Conversation) -> ConversationResponse:
    result = await db.execute(
        select(ConversationParticipant.user_id).where(ConversationParticipant.conversation_id == conv.id)
    )
    participant_ids = [row[0] for row in result.all()]

    names_result = await db.execute(select(User.id, User.display_name).where(User.id.in_(participant_ids)))
    display_names = {row[0]: row[1] for row in names_result.all()}

    return ConversationResponse(
        id=conv.id, type=conv.type, name=conv.name,
        participant_user_ids=participant_ids,
        participant_display_names=display_names,
        created_at=conv.created_at, updated_at=conv.updated_at,
    )


@router.post("", response_model=ConversationResponse)
async def create_conversation(
    payload: CreateConversationRequest,
    current=Depends(get_current_device),
    db: AsyncSession = Depends(get_db),
):
    user_id, _device_id = current
    if payload.type == "direct" and len(payload.participant_user_ids) != 1:
        raise HTTPException(status_code=400, detail="direct conversation needs exactly one other participant")

    conv = Conversation(type=payload.type, name=payload.name)
    db.add(conv)
    await db.flush()

    all_ids = set(payload.participant_user_ids) | {user_id}
    for uid in all_ids:
        role = "admin" if payload.type == "group" and uid == user_id else "member"
        db.add(
            ConversationParticipant(
                conversation_id=conv.id,
                user_id=uid,
                role=role,
            )
        )
    await db.commit()
    await db.refresh(conv)

    return await _to_response(db, conv)


@router.put("/{conversation_id}/members/{user_id}/role")
async def set_member_role(
    conversation_id: str,
    user_id: str,
    payload: GroupMemberRoleRequest,
    current=Depends(get_current_device),
    db: AsyncSession = Depends(get_db),
):
    caller_user_id, _ = current
    _conv, caller = await _require_participant(
        db, conversation_id, caller_user_id
    )
    if caller.role != "admin":
        raise HTTPException(status_code=403, detail="Group admin role required")

    target = (
        await db.execute(
            select(ConversationParticipant).where(
                ConversationParticipant.conversation_id == conversation_id,
                ConversationParticipant.user_id == user_id,
            )
        )
    ).scalar_one_or_none()
    if target is None:
        raise HTTPException(status_code=404, detail="Group member not found")

    if target.role == "admin" and payload.role == "member":
        other_admin = (
            await db.execute(
                select(ConversationParticipant.id).where(
                    ConversationParticipant.conversation_id == conversation_id,
                    ConversationParticipant.user_id != user_id,
                    ConversationParticipant.role == "admin",
                )
            )
        ).first()
        if other_admin is None:
            raise HTTPException(
                status_code=409,
                detail="Cannot demote the last group admin",
            )

    target.role = payload.role
    await db.commit()
    return {"status": "ok", "user_id": user_id, "role": target.role}


@router.get("", response_model=list[ConversationResponse])
async def list_conversations(current=Depends(get_current_device), db: AsyncSession = Depends(get_db)):
    user_id, _device_id = current
    result = await db.execute(
        select(Conversation)
        .join(ConversationParticipant, ConversationParticipant.conversation_id == Conversation.id)
        .where(ConversationParticipant.user_id == user_id)
        .order_by(Conversation.updated_at.desc())
    )
    convs = result.scalars().all()
    return [await _to_response(db, c) for c in convs]


@router.get("/{conversation_id}", response_model=ConversationResponse)
async def get_conversation(
    conversation_id: str,
    current=Depends(get_current_device),
    db: AsyncSession = Depends(get_db),
):
    user_id, _device_id = current
    conv = await db.get(Conversation, conversation_id)
    if not conv:
        raise HTTPException(status_code=404, detail="Not found")
    result = await db.execute(
        select(ConversationParticipant).where(
            ConversationParticipant.conversation_id == conversation_id,
            ConversationParticipant.user_id == user_id,
        )
    )
    if not result.scalar_one_or_none():
        raise HTTPException(status_code=403, detail="Not a participant")
    return await _to_response(db, conv)


async def _require_participant(
    db: AsyncSession, conversation_id: str, user_id: str
) -> tuple[Conversation, ConversationParticipant]:
    """Load group conversation and verify caller is a participant."""
    conv = await db.get(Conversation, conversation_id)
    if not conv:
        raise HTTPException(status_code=404, detail="Not found")
    if conv.type != "group":
        raise HTTPException(status_code=400, detail="Only group conversations support member management")
    result = await db.execute(
        select(ConversationParticipant).where(
            ConversationParticipant.conversation_id == conversation_id,
            ConversationParticipant.user_id == user_id,
        )
    )
    participant = result.scalar_one_or_none()
    if not participant:
        raise HTTPException(status_code=403, detail="Not a participant")
    return conv, participant


@router.post("/{conversation_id}/members")
async def add_members(
    conversation_id: str,
    payload: AddMembersRequest,
    current=Depends(get_current_device),
    db: AsyncSession = Depends(get_db),
):
    """Add one or more users to a group conversation."""
    user_ids = payload.user_ids
    caller_user_id, _ = current
    conv, caller = await _require_participant(db, conversation_id, caller_user_id)
    if caller.role != "admin":
        raise HTTPException(status_code=403, detail="Group admin role required")

    # Find which user_ids are valid users
    result = await db.execute(select(User.id).where(User.id.in_(user_ids)))
    valid_ids = {row[0] for row in result.all()}
    invalid = set(user_ids) - valid_ids
    if invalid:
        raise HTTPException(status_code=404, detail=f"Users not found: {list(invalid)}")

    # Find which are already in the conversation
    existing_result = await db.execute(
        select(ConversationParticipant.user_id).where(
            ConversationParticipant.conversation_id == conversation_id,
            ConversationParticipant.user_id.in_(user_ids),
        )
    )
    already_in = {row[0] for row in existing_result.all()}
    to_add = valid_ids - already_in

    for uid in to_add:
        db.add(ConversationParticipant(conversation_id=conversation_id, user_id=uid, role="member"))

    await db.commit()
    await db.refresh(conv)
    return await _to_response(db, conv)


@router.delete("/{conversation_id}/members/{user_id}")
async def remove_member(
    conversation_id: str,
    user_id: str,
    current=Depends(get_current_device),
    db: AsyncSession = Depends(get_db),
):
    """Allow members to leave and administrators to remove other members."""
    caller_user_id, _ = current
    _conv, caller = await _require_participant(
        db, conversation_id, caller_user_id
    )

    target_result = await db.execute(
        select(ConversationParticipant).where(
            ConversationParticipant.conversation_id == conversation_id,
            ConversationParticipant.user_id == user_id,
        )
    )
    target = target_result.scalar_one_or_none()
    if target is None:
        raise HTTPException(status_code=404, detail="Group member not found")
    if user_id != caller_user_id and caller.role != "admin":
        raise HTTPException(status_code=403, detail="Group admin role required")

    # Cannot remove the last participant
    count_result = await db.execute(
        select(ConversationParticipant).where(
            ConversationParticipant.conversation_id == conversation_id,
        )
    )
    count = len(count_result.scalars().all())
    if count <= 1:
        raise HTTPException(status_code=400, detail="Cannot remove the last participant")

    if target.role == "admin":
        other_admin = (
            await db.execute(
                select(ConversationParticipant).where(
                    ConversationParticipant.conversation_id == conversation_id,
                    ConversationParticipant.user_id != user_id,
                    ConversationParticipant.role == "admin",
                )
            )
        ).scalars().first()
        if other_admin is None:
            successor = (
                await db.execute(
                    select(ConversationParticipant)
                    .where(
                        ConversationParticipant.conversation_id == conversation_id,
                        ConversationParticipant.user_id != user_id,
                    )
                    .order_by(
                        ConversationParticipant.joined_at.asc(),
                        ConversationParticipant.id.asc(),
                    )
                    .limit(1)
                )
            ).scalar_one()
            successor.role = "admin"

    await db.execute(
        delete(ConversationParticipant).where(
            ConversationParticipant.conversation_id == conversation_id,
            ConversationParticipant.user_id == user_id,
        )
    )
    await db.commit()
    return {"status": "ok", "removed_user_id": user_id}


@router.put("/{conversation_id}/disappearing-ttl")
async def set_disappearing_ttl(
    conversation_id: str,
    ttl_seconds: int = Body(..., embed=True, ge=0),
    current=Depends(get_current_device),
    db: AsyncSession = Depends(get_db),
):
    """Установить TTL исчезающих сообщений (Task #70).

    ttl_seconds=0 отключает исчезающие сообщения для этого разговора.
    Только участники разговора могут менять настройку.
    Уже отправленные сообщения не меняются — TTL применяется только к новым.
    """
    caller_user_id, _ = current
    conv = await db.get(Conversation, conversation_id)
    if not conv:
        raise HTTPException(status_code=404, detail="Not found")
    # Проверить что caller — участник
    result = await db.execute(
        select(ConversationParticipant).where(
            ConversationParticipant.conversation_id == conversation_id,
            ConversationParticipant.user_id == caller_user_id,
        )
    )
    if not result.scalar_one_or_none():
        raise HTTPException(status_code=403, detail="Not a participant")

    conv.disappearing_ttl_seconds = ttl_seconds if ttl_seconds > 0 else None
    await db.commit()

    # Оповестить всех участников через WS
    from app.ws import manager as ws_manager
    participants = await db.execute(
        select(ConversationParticipant.user_id).where(
            ConversationParticipant.conversation_id == conversation_id
        )
    )
    for (uid,) in participants:
        await ws_manager.send_to_user(uid, {
            "type": "disappearing_ttl_changed",
            "conversation_id": conversation_id,
            "ttl_seconds": ttl_seconds if ttl_seconds > 0 else None,
            "changed_by": caller_user_id,
        })

    return {
        "conversation_id": conversation_id,
        "disappearing_ttl_seconds": conv.disappearing_ttl_seconds,
    }
