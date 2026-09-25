"""Исчезающие сообщения (Task #70 — Disappearing Messages TTL).

Сервер устанавливает expires_at при сохранении каждого нового сообщения.
Жёсткий серверный retention ограничен 24 часами; пользовательский
Conversation.disappearing_ttl_seconds может сделать срок только короче.

Фоновый воркер delete_expired_messages() запускается из lifespan (main.py)
и каждые SWEEP_INTERVAL_SECONDS удаляет все Message.expires_at < now().

После удаления — WS-push всем участникам разговора (type: "message_deleted")
чтобы клиент убрал из UI без перезагрузки.
"""
from __future__ import annotations

import asyncio
import logging
from datetime import datetime, timedelta, timezone

from sqlalchemy import delete, select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.config import settings
from app.models import (
    Conversation,
    ConversationParticipant,
    Message,
    MessageDeliveryAck,
    MessageOutbox,
)
from app.ws import manager

_logger = logging.getLogger(__name__)

SWEEP_INTERVAL_SECONDS = settings.disappearing_sweep_seconds


async def apply_ttl_to_message(
    message: Message,
    conversation: Conversation,
) -> None:
    """Apply the shorter of server retention and conversation TTL."""
    conversation_ttl = conversation.disappearing_ttl_seconds
    ttl = settings.server_message_retention_seconds
    if conversation_ttl and conversation_ttl > 0:
        ttl = min(ttl, conversation_ttl)
    message.expires_at = datetime.now(timezone.utc) + timedelta(seconds=ttl)


async def delete_expired_messages(session_factory: async_sessionmaker) -> None:
    """Фоновый sweep: удаляет просроченные сообщения, пушит WS-события."""
    while True:
        try:
            await asyncio.sleep(SWEEP_INTERVAL_SECONDS)
            async with session_factory() as db:
                await _sweep(db)
        except asyncio.CancelledError:
            break
        except Exception as exc:  # noqa: BLE001
            _logger.exception("disappearing sweep error: %s", exc)


async def _sweep(db: AsyncSession) -> None:
    now = datetime.now(timezone.utc)
    metadata_cutoff = (
        now - timedelta(seconds=settings.server_message_retention_seconds)
    ).replace(tzinfo=None)

    # ACK rows contain communication metadata and outbox rows contain complete
    # opaque envelopes. Neither may outlive the same hard server retention.
    await db.execute(
        delete(MessageDeliveryAck).where(
            MessageDeliveryAck.acked_at <= metadata_cutoff
        )
    )
    await db.execute(
        delete(MessageOutbox).where(MessageOutbox.created_at <= metadata_cutoff)
    )
    await db.commit()

    # Найти просроченные сообщения (с разговором для WS push)
    result = await db.execute(
        select(Message).where(
            Message.expires_at != None,  # noqa: E711
            Message.expires_at <= now,
        ).limit(500)
    )
    messages = result.scalars().all()
    if not messages:
        return

    _logger.info("Sweeping %d expired messages", len(messages))

    # Group expired rows by conversation before deletion. Server retention
    # removes only the transient Home copy. A client-side deletion event is
    # emitted exclusively for an explicit disappearing-message policy.
    by_conv: dict[str, list[str]] = {}
    for msg in messages:
        by_conv.setdefault(msg.conversation_id, []).append(msg.id)

    conversation_rows = await db.execute(
        select(Conversation.id, Conversation.disappearing_ttl_seconds).where(
            Conversation.id.in_(by_conv)
        )
    )
    disappearing_conversations = {
        conversation_id
        for conversation_id, ttl in conversation_rows.all()
        if ttl and 0 < ttl <= settings.server_message_retention_seconds
    }

    # Удаляем
    ids = [m.id for m in messages]
    await db.execute(delete(Message).where(Message.id.in_(ids)))
    await db.commit()

    # WS push участникам каждого разговора
    for conv_id, msg_ids in by_conv.items():
        if conv_id not in disappearing_conversations:
            continue
        # Найти участников разговора
        participants = await db.execute(
            select(ConversationParticipant.user_id).where(
                ConversationParticipant.conversation_id == conv_id
            )
        )
        user_ids = [row[0] for row in participants]
        for user_id in user_ids:
            for msg_id in msg_ids:
                await manager.send_to_user(
                    user_id,
                    {
                        "type": "message_deleted",
                        "message_id": msg_id,
                        "conversation_id": conv_id,
                        "reason": "expired",
                    },
                )
