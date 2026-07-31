"""Исчезающие сообщения (Task #70 — Disappearing Messages TTL).

Сервер устанавливает expires_at при сохранении каждого нового сообщения
если у Conversation.disappearing_ttl_seconds > 0.

Фоновый воркер delete_expired_messages() запускается из lifespan (main.py)
и каждые SWEEP_INTERVAL_SECONDS удаляет все Message.expires_at < now().

После удаления — WS-push всем участникам разговора (type: "message_deleted")
чтобы клиент убрал из UI без перезагрузки.
"""
from __future__ import annotations

import asyncio
import logging
import os
from datetime import datetime, timedelta, timezone

from sqlalchemy import delete, select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.models import Conversation, ConversationParticipant, Message
from app.ws import manager

_logger = logging.getLogger(__name__)

SWEEP_INTERVAL_SECONDS = int(os.environ.get("DISAPPEARING_SWEEP_SECONDS", "30"))


async def apply_ttl_to_message(
    message: Message,
    conversation: Conversation,
) -> None:
    """Проставить expires_at если у разговора задан TTL.
    Вызывается до db.commit() в send_message и deliver."""
    ttl = conversation.disappearing_ttl_seconds
    if ttl and ttl > 0:
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

    # Группируем по разговорам для push
    by_conv: dict[str, list[str]] = {}
    for msg in messages:
        by_conv.setdefault(msg.conversation_id, []).append(msg.id)

    # Удаляем
    ids = [m.id for m in messages]
    await db.execute(delete(Message).where(Message.id.in_(ids)))
    await db.commit()

    # WS push участникам каждого разговора
    for conv_id, msg_ids in by_conv.items():
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
