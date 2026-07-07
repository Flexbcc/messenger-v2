from sqlalchemy import select
from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import get_db
from app.deps import get_current_device
from app.models import Conversation, ConversationParticipant, User
from app.schemas import ConversationResponse, CreateConversationRequest

router = APIRouter(prefix="/conversations", tags=["conversations"])


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
        db.add(ConversationParticipant(conversation_id=conv.id, user_id=uid, role="member"))
    await db.commit()
    await db.refresh(conv)

    return await _to_response(db, conv)


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
