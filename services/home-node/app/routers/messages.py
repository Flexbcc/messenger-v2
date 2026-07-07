"""
Send + paginated history. Pagination cursor pattern (`before` + `limit`)
ported from ~/secret_room/backend/app/api/messages.py (ADR-0005).
"""
from datetime import datetime, timezone
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import get_db
from app.deps import get_current_device
from app.fanout import fan_out_message
from app.models import Conversation, ConversationParticipant, Message, User
from app.schemas import MessageResponse, SendMessageRequest

router = APIRouter(prefix="/conversations", tags=["messages"])


async def _assert_participant(db: AsyncSession, conversation_id: str, user_id: str) -> Conversation:
    conv = await db.get(Conversation, conversation_id)
    if not conv:
        raise HTTPException(status_code=404, detail="Conversation not found")
    result = await db.execute(
        select(ConversationParticipant).where(
            ConversationParticipant.conversation_id == conversation_id,
            ConversationParticipant.user_id == user_id,
        )
    )
    if not result.scalar_one_or_none():
        raise HTTPException(status_code=403, detail="Not a participant")
    return conv


def _to_response(m: Message, sender_display_name: Optional[str] = None) -> MessageResponse:
    return MessageResponse(
        id=m.id, conversation_id=m.conversation_id, sender_user_id=m.sender_user_id,
        sender_device_id=m.sender_device_id, sender_display_name=sender_display_name,
        ciphertext=m.ciphertext,
        content_type=m.content_type, crypto_version=m.crypto_version,
        created_at=m.created_at.replace(tzinfo=timezone.utc),
    )


@router.post("/{conversation_id}/messages", response_model=MessageResponse)
async def send_message(
    conversation_id: str,
    payload: SendMessageRequest,
    current=Depends(get_current_device),
    db: AsyncSession = Depends(get_db),
):
    user_id, device_id = current
    conv = await _assert_participant(db, conversation_id, user_id)

    message = Message(
        conversation_id=conversation_id,
        sender_user_id=user_id,
        sender_device_id=device_id,
        client_msg_id=payload.client_msg_id,
        ciphertext=payload.ciphertext,
        content_type=payload.content_type,
        crypto_version=payload.crypto_version,
    )
    db.add(message)
    conv.updated_at = datetime.utcnow()
    await db.commit()
    await db.refresh(message)

    await fan_out_message(db, conv, message)

    sender = await db.get(User, user_id)
    return _to_response(message, sender.display_name if sender else None)


@router.get("/{conversation_id}/messages", response_model=list[MessageResponse])
async def get_messages(
    conversation_id: str,
    limit: int = 50,
    before: Optional[str] = None,
    current=Depends(get_current_device),
    db: AsyncSession = Depends(get_db),
):
    user_id, _device_id = current
    await _assert_participant(db, conversation_id, user_id)

    query = select(Message).where(Message.conversation_id == conversation_id)
    if before:
        query = query.where(Message.created_at < datetime.fromisoformat(before))
    query = query.order_by(Message.created_at.desc()).limit(min(limit, 200))

    result = await db.execute(query)
    messages = result.scalars().all()

    sender_ids = {m.sender_user_id for m in messages}
    names_result = await db.execute(select(User.id, User.display_name).where(User.id.in_(sender_ids)))
    display_names = {row[0]: row[1] for row in names_result.all()}

    return [_to_response(m, display_names.get(m.sender_user_id)) for m in messages]
