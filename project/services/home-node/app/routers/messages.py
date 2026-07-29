"""
Send + paginated history. Pagination cursor pattern (`before` + `limit`)
ported from ~/secret_room/backend/app/api/messages.py (ADR-0005).
"""
from datetime import datetime, timezone
from typing import Optional

from fastapi import APIRouter, Body, Depends, HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import get_db
from app.deps import get_current_device
from app.disappearing import apply_ttl_to_message
from app.fanout import fan_out_message, handle_delivery_ack, upsert_delivery_ack
from app.models import Conversation, ConversationParticipant, FederatedMediaRef, Message, MessageEdit, User
from app.schemas import (
    AckMessageRequest, DeliveryAckResponse, MessagePage, MessageResponse,
    SendMessageRequest, UpdateDeliveryStatusRequest, MessageStatusUpdateEvent,
)

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
    def _utc(dt: Optional[datetime]) -> Optional[datetime]:
        if dt is None:
            return None
        return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)

    return MessageResponse(
        id=m.id, conversation_id=m.conversation_id, sender_user_id=m.sender_user_id,
        sender_device_id=m.sender_device_id, sender_display_name=sender_display_name,
        ciphertext=m.ciphertext,
        content_type=m.content_type, crypto_version=m.crypto_version,
        created_at=_utc(m.created_at),
        delivery_status=getattr(m, "delivery_status", "sent") or "sent",
        delivered_at=_utc(getattr(m, "delivered_at", None)),
        read_at=_utc(getattr(m, "read_at", None)),
        expires_at=_utc(getattr(m, "expires_at", None)),
        edited_at=_utc(getattr(m, "edited_at", None)),
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

    device_envelopes_json = (
        [de.model_dump() for de in payload.device_envelopes]
        if payload.device_envelopes else None
    )
    message = Message(
        conversation_id=conversation_id,
        sender_user_id=user_id,
        sender_device_id=device_id,
        client_msg_id=payload.client_msg_id,
        ciphertext=payload.ciphertext,
        content_type=payload.content_type,
        crypto_version=payload.crypto_version,
        device_envelopes=device_envelopes_json,
        origin_media_node_url=payload.media_node_url,
    )
    db.add(message)
    # Исчезающие сообщения (Task #70): проставить expires_at если TTL задан
    await apply_ttl_to_message(message, conv)
    conv.updated_at = datetime.utcnow()
    # Storage federation (Task #63): сохраняем маппинг media_id → this Media-node
    # чтобы получатели на других Home могли найти откуда скачивать медиа.
    if payload.media_ids and payload.media_node_url:
        from app.config import settings as _settings
        origin_url = payload.media_node_url or _settings.media_node_url
        for mid in payload.media_ids:
            existing = await db.get(FederatedMediaRef, mid)
            if not existing:
                db.add(FederatedMediaRef(media_id=mid, origin_media_node_url=origin_url))
    await db.commit()
    await db.refresh(message)

    await fan_out_message(db, conv, message)

    sender = await db.get(User, user_id)
    return _to_response(message, sender.display_name if sender else None)


@router.get("/{conversation_id}/messages", response_model=MessagePage)
async def get_messages(
    conversation_id: str,
    limit: int = 50,
    before: Optional[str] = None,
    after: Optional[str] = None,
    current=Depends(get_current_device),
    db: AsyncSession = Depends(get_db),
):
    """`before=` — пагинация назад (load more): сообщения с created_at < before,
    сортировка desc (новые первыми). `after=` — догон новых (multi-device catch-up):
    сообщения с created_at > after, сортировка asc. Возвращает MessagePage с
    has_more=True и next_cursor когда есть ещё страницы.
    max limit=200."""
    user_id, _device_id = current
    await _assert_participant(db, conversation_id, user_id)

    capped = min(max(1, limit), 200)
    # Запрашиваем на 1 больше чтобы определить has_more
    fetch_limit = capped + 1

    query = select(Message).where(Message.conversation_id == conversation_id)
    if before:
        try:
            query = query.where(Message.created_at < datetime.fromisoformat(before))
        except ValueError:
            raise HTTPException(status_code=400, detail="Неверный формат before (ожидается ISO datetime)")
    if after:
        try:
            query = query.where(Message.created_at > datetime.fromisoformat(after))
        except ValueError:
            raise HTTPException(status_code=400, detail="Неверный формат after (ожидается ISO datetime)")

    asc_order = bool(after)
    query = query.order_by(
        Message.created_at.asc() if asc_order else Message.created_at.desc()
    ).limit(fetch_limit)

    result = await db.execute(query)
    rows = result.scalars().all()

    has_more = len(rows) > capped
    messages = rows[:capped]

    # next_cursor — created_at крайнего сообщения (для следующего before=)
    next_cursor: Optional[str] = None
    if has_more and messages:
        oldest = messages[-1] if not asc_order else messages[0]
        next_cursor = oldest.created_at.isoformat()

    sender_ids = {m.sender_user_id for m in messages}
    names_result = await db.execute(
        select(User.id, User.display_name).where(User.id.in_(sender_ids))
    )
    display_names = {row[0]: row[1] for row in names_result.all()}

    items = [_to_response(m, display_names.get(m.sender_user_id)) for m in messages]
    return MessagePage(items=items, has_more=has_more, next_cursor=next_cursor)


@router.post("/{conversation_id}/messages/{packet_id}/ack", response_model=DeliveryAckResponse)
async def ack_message(
    conversation_id: str,
    packet_id: str,
    payload: AckMessageRequest = AckMessageRequest(),
    current=Depends(get_current_device),
    db: AsyncSession = Depends(get_db),
):
    """Post-R5 semantic e2e delivery ACK (spec/0202_DELIVERY.md). Caller must
    be a participant of conversation_id; idempotent — acking the same
    packet_id twice from the same user still returns 200."""
    user_id, _device_id = current
    await _assert_participant(db, conversation_id, user_id)

    message = await db.get(Message, packet_id)
    if not message or message.conversation_id != conversation_id:
        raise HTTPException(status_code=404, detail="Message not found")

    acked_at = await upsert_delivery_ack(
        db, packet_id=packet_id, conversation_id=conversation_id, from_user_id=user_id
    )
    await handle_delivery_ack(db, message=message, from_user_id=user_id, acked_at=acked_at)

    return DeliveryAckResponse()


_STATUS_ORDER = {"sent": 0, "delivered": 1, "read": 2}


@router.patch("/{conversation_id}/messages/{message_id}/status", response_model=MessageResponse)
async def update_message_status(
    conversation_id: str,
    message_id: str,
    payload: UpdateDeliveryStatusRequest,
    current=Depends(get_current_device),
    db: AsyncSession = Depends(get_db),
):
    """
    Обновить статус доставки сообщения: delivered или read.
    Вызывается получателем. Статус может только расти: sent→delivered→read.
    После обновления WS-событие message_status_update рассылается отправителю.
    """
    user_id, _device_id = current
    await _assert_participant(db, conversation_id, user_id)

    if payload.status not in ("delivered", "read"):
        raise HTTPException(status_code=400, detail="status must be 'delivered' or 'read'")

    message = await db.get(Message, message_id)
    if not message or message.conversation_id != conversation_id:
        raise HTTPException(status_code=404, detail="Message not found")

    # Статус может только расти
    current_rank = _STATUS_ORDER.get(getattr(message, "delivery_status", "sent") or "sent", 0)
    new_rank = _STATUS_ORDER[payload.status]
    if new_rank <= current_rank:
        # Уже в этом или более высоком статусе — идемпотентно
        sender = await db.get(User, message.sender_user_id)
        return _to_response(message, sender.display_name if sender else None)

    now = datetime.utcnow()
    message.delivery_status = payload.status  # type: ignore[assignment]
    if payload.status == "delivered":
        message.delivered_at = now  # type: ignore[assignment]
    elif payload.status == "read":
        if not getattr(message, "delivered_at", None):
            message.delivered_at = now  # type: ignore[assignment]
        message.read_at = now  # type: ignore[assignment]

    await db.commit()
    await db.refresh(message)

    # WS-событие отправителю
    try:
        from app.ws import manager
        event = MessageStatusUpdateEvent(
            message_id=message_id,
            conversation_id=conversation_id,
            status=payload.status,
            updated_by=user_id,
            updated_at=now.replace(tzinfo=timezone.utc),
        )
        await manager.send_to_user(message.sender_user_id, event.model_dump(mode="json"))
    except Exception:
        pass  # WS — best-effort

    sender = await db.get(User, message.sender_user_id)
    return _to_response(message, sender.display_name if sender else None)


# ---------------------------------------------------------------------------
# Task #71 — Редактирование отправленных сообщений
# ---------------------------------------------------------------------------

import os as _os

_EDIT_WINDOW_SECONDS = int(_os.environ.get("MESSAGE_EDIT_WINDOW_SECONDS", "300"))  # 5 минут


@router.patch("/{conversation_id}/messages/{message_id}")
async def edit_message(
    conversation_id: str,
    message_id: str,
    new_ciphertext: str = Body(..., embed=True),
    current=Depends(get_current_device),
    db: AsyncSession = Depends(get_db),
):
    """Редактировать отправленное сообщение (Task #71).

    Только отправитель может редактировать своё сообщение.
    Редактирование разрешено только в течение MESSAGE_EDIT_WINDOW_SECONDS (по умолчанию 5 минут).
    Старый ciphertext сохраняется в MessageEdit (история правок).
    WS-событие message_edited рассылается всем участникам разговора.
    """
    user_id, _device_id = current
    await _assert_participant(db, conversation_id, user_id)

    message = await db.get(Message, message_id)
    if not message or message.conversation_id != conversation_id:
        raise HTTPException(status_code=404, detail="Message not found")

    if message.sender_user_id != user_id:
        raise HTTPException(status_code=403, detail="Only the sender can edit their message")

    # Проверяем окно редактирования
    msg_age = (datetime.now(timezone.utc) - message.created_at.replace(tzinfo=timezone.utc)).total_seconds()
    if msg_age > _EDIT_WINDOW_SECONDS:
        raise HTTPException(
            status_code=403,
            detail=f"Edit window expired ({_EDIT_WINDOW_SECONDS}s). Message is {int(msg_age)}s old."
        )

    # Сохраняем старую версию в историю
    db.add(MessageEdit(message_id=message_id, old_ciphertext=message.ciphertext))

    # Обновляем сообщение
    message.ciphertext = new_ciphertext
    message.edited_at = datetime.now(timezone.utc)
    await db.commit()
    await db.refresh(message)

    # WS push всем участникам разговора
    try:
        from app.ws import manager
        from sqlalchemy import select as _select
        from app.models import ConversationParticipant as _CP
        participants = await db.execute(
            _select(_CP.user_id).where(_CP.conversation_id == conversation_id)
        )
        for (uid,) in participants:
            await manager.send_to_user(uid, {
                "type": "message_edited",
                "message_id": message_id,
                "conversation_id": conversation_id,
                "new_ciphertext": new_ciphertext,
                "edited_at": message.edited_at.isoformat(),
                "edited_by": user_id,
            })
    except Exception:
        pass

    sender = await db.get(User, user_id)
    return _to_response(message, sender.display_name if sender else None)
