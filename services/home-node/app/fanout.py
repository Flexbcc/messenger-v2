"""
Message fan-out: local delivery + cross-Home-Node federation for a single
Conversation. This is the concrete implementation of the routing model
described in spec/0203_ROUTING.md (direct delivery, falling back to
Storage Node buffering) plus the federation forwarding pattern from
ADR-0005, generalized from 1:1 to N participants.

MVP simplification: delivery is routed per-user, not per-Device as the
full spec envisions (spec/0102_DATA_FLOW.md fan-out to every active Device).
Revisit once multi-device sync is implemented.
"""
import uuid
from datetime import datetime, timezone

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import settings
from app.federation import resolve_home_node, deliver_to_remote_home_node, buffer_for_offline_user
from app.models import Conversation, ConversationParticipant, User
from app.ws import manager


def _envelope_from_message(conversation_id: str, message) -> dict:
    return {
        "packet_id": message.id,
        "type": "MESSAGE",
        "conversation_id": conversation_id,
        "sender_user_id": message.sender_user_id,
        "sender_device_id": message.sender_device_id,
        "crypto_version": message.crypto_version,
        "ciphertext": message.ciphertext,
        "content_type": message.content_type,
        "created_at": message.created_at.replace(tzinfo=timezone.utc).isoformat(),
    }


async def fan_out_message(db: AsyncSession, conversation: Conversation, message) -> None:
    envelope = _envelope_from_message(conversation.id, message)

    result = await db.execute(
        select(ConversationParticipant).where(ConversationParticipant.conversation_id == conversation.id)
    )
    participants = result.scalars().all()

    remote_targets: dict[str, list[str]] = {}

    for p in participants:
        if p.user_id == message.sender_user_id:
            continue

        local_user = await db.get(User, p.user_id)
        if local_user:
            delivered = await manager.send_to_user(p.user_id, {"type": "new_message", "message": envelope})
            if not delivered:
                await buffer_for_offline_user(p.user_id, envelope)
            continue

        home_node_url = await resolve_home_node(p.user_id)
        if home_node_url and home_node_url != settings.public_url:
            remote_targets.setdefault(home_node_url, []).append(p.user_id)
        # else: unknown participant — nothing we can do for them in MVP.

    if remote_targets:
        conversation_meta = {
            "conversation_id": conversation.id,
            "type": conversation.type,
            "name": conversation.name,
            "participant_user_ids": [p.user_id for p in participants],
        }
        for home_node_url in remote_targets:
            try:
                await deliver_to_remote_home_node(home_node_url, envelope, conversation_meta)
            except Exception:
                # Non-fatal for the sender's own request; a production system
                # would retry with backoff per spec/0202_DELIVERY.md.
                import logging
                logging.getLogger(__name__).warning(
                    "Federation delivery to %s failed for conversation %s", home_node_url, conversation.id
                )


async def upsert_conversation_mirror(db: AsyncSession, conversation_meta: dict) -> Conversation:
    """Called by /internal/deliver when this Home Node first sees a
    federated Conversation it wasn't the origin of."""
    conv = await db.get(Conversation, conversation_meta["conversation_id"])
    if not conv:
        conv = Conversation(
            id=conversation_meta["conversation_id"],
            type=conversation_meta["type"],
            name=conversation_meta.get("name"),
        )
        db.add(conv)
        await db.flush()

    existing = await db.execute(
        select(ConversationParticipant.user_id).where(ConversationParticipant.conversation_id == conv.id)
    )
    existing_ids = {row[0] for row in existing.all()}
    for uid in conversation_meta["participant_user_ids"]:
        if uid not in existing_ids:
            db.add(ConversationParticipant(conversation_id=conv.id, user_id=uid))
    await db.commit()
    return conv


async def deliver_locally_for_federated_message(db: AsyncSession, conversation_meta: dict, envelope: dict) -> None:
    for uid in conversation_meta["participant_user_ids"]:
        if uid == envelope["sender_user_id"]:
            continue
        local_user = await db.get(User, uid)
        if not local_user:
            continue
        delivered = await manager.send_to_user(uid, {"type": "new_message", "message": envelope})
        if not delivered:
            await buffer_for_offline_user(uid, envelope)
