"""
Message fan-out: local delivery + cross-Home-Node federation for a single
Conversation. This is the concrete implementation of the routing model
described in spec/0203_ROUTING.md (direct delivery, falling back to
Storage Node buffering) plus the federation forwarding pattern from
ADR-0005, generalized from 1:1 to N participants.

Per-device envelopes are routed and acknowledged against the immutable target
snapshot stored with each transient Message. Legacy envelopes without device
targets retain the user-level compatibility ACK path.
"""
import logging
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Literal, Optional

from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import settings
from app.push_notify import notify_incoming_call, notify_new_message
from app.federation import (
    buffer_for_offline_user,
    deliver_to_remote_home_node,
    notify_remote_delivery_ack,
    notify_remote_home_changed,
    resolve_home_node,
)
from app.models import Conversation, ConversationParticipant, Device, Message, MessageDeliveryAck, User
from app.outbox import enqueue_outbox
from app.ws import manager

logger = logging.getLogger(__name__)


LocalDeliveryChannel = Literal["online", "mailbox", "mixed", "no_target"]


@dataclass(frozen=True)
class FederatedHomeAcceptance:
    """What the recipient Home accepted, without claiming a device ACK.

    ``online`` means that the Home wrote the envelope to at least one active
    device socket.  ``mailbox`` means it durably buffered the opaque envelope.
    Neither value means that a device decrypted or acknowledged the message.
    """

    online_recipients: int = 0
    mailbox_recipients: int = 0
    ignored_recipients: int = 0

    @property
    def disposition(self) -> str:
        if self.online_recipients and self.mailbox_recipients:
            return "mixed"
        if self.online_recipients:
            return "online"
        if self.mailbox_recipients:
            return "mailbox"
        return "no_local_target"


def _envelope_from_message(conversation_id: str, message) -> dict:
    env = {
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
    if message.device_envelopes:
        env["device_envelopes"] = message.device_envelopes
    if message.media_ids:
        env["media_ids"] = message.media_ids
    # Storage federation (Task #63): передаём URL нашего Media-node чтобы
    # получатели на других Home могли скачать медиа через federation fallback.
    # origin_media_node_url — URL источника (если это пришедшее federated сообщение)
    # иначе наш собственный media-node (для исходящих сообщений).
    if message.content_type in ("image", "file", "voice", "video"):
        env["media_node_url"] = message.origin_media_node_url or settings.media_node_url
    return env


async def delivery_target_snapshot(
    db: AsyncSession,
    *,
    device_envelopes: list[dict] | None,
    local_user_ids: set[str] | None = None,
    exclude_user_id: str | None = None,
) -> list[str] | None:
    """Resolve an immutable, bounded device target set for this Home copy.

    A sender Home excludes all devices owned by the sender. A recipient Home
    intersects the opaque envelope IDs with devices owned by its local target
    users. No future device registration changes this snapshot.
    """
    if not device_envelopes:
        return None
    supplied = {
        item.get("device_id")
        for item in device_envelopes
        if isinstance(item, dict) and isinstance(item.get("device_id"), str)
    }
    supplied.discard(None)
    if not supplied:
        return None
    query = select(Device.id, Device.user_id).where(Device.id.in_(supplied))
    rows = (await db.execute(query)).all()
    if local_user_ids is not None:
        return sorted(
            device_id
            for device_id, user_id in rows
            if user_id in local_user_ids
        ) or None
    locally_excluded = {
        device_id
        for device_id, user_id in rows
        if exclude_user_id is not None and user_id == exclude_user_id
    }
    return sorted(supplied - locally_excluded) or None


async def _deliver_locally(
    db: AsyncSession,
    user_id: str,
    envelope: dict,
    *,
    exclude_device_id: str | None = None,
) -> LocalDeliveryChannel:
    """
    Deliver to a local user. If envelope has device_envelopes, route each
    ciphertext to the specific device's WebSocket. Falls back to broadcast
    for devices that aren't online (buffered) or for legacy envelopes.
    Returns only the Home-side channel used. A socket write is deliberately
    not called a delivery ACK: the device sends that separately after receipt.
    """
    device_envelopes: list[dict] | None = envelope.get("device_envelopes")

    if device_envelopes:
        owned_device_ids = set((await db.execute(
            select(Device.id).where(Device.user_id == user_id)
        )).scalars().all())
        targeted_envelopes = [
            item for item in device_envelopes
            if item.get("device_id") in owned_device_ids
            and item.get("device_id") != exclude_device_id
        ]
        if not targeted_envelopes:
            return "no_target"
        # Per-device E2EE: send each ciphertext only to its target device
        delivered_any = False
        offline_target_exists = False
        for de in targeted_envelopes:
            device_id = de.get("device_id")
            if not device_id:
                continue
            per_device_env = {**envelope, "ciphertext": de["ciphertext"]}
            per_device_env.pop("device_envelopes", None)
            ok = await manager.send_to_device(device_id, {"type": "new_message", "message": per_device_env})
            if ok:
                delivered_any = True
            else:
                offline_target_exists = True
        # A single per-user opaque mailbox copy retains all device envelopes.
        # It is necessary even when another target device was online; cleanup
        # waits for the complete per-device ACK set.
        if offline_target_exists:
            await buffer_for_offline_user(user_id, envelope)
            if delivered_any:
                return "mixed"
            return "mailbox"
        return "online"
    else:
        # Legacy broadcast (groups, no per-device envelopes, compat)
        delivered = await manager.send_to_user(user_id, {"type": "new_message", "message": envelope})
        if not delivered:
            await buffer_for_offline_user(user_id, envelope)
            return "mailbox"
        return "online"


_CALL_OFFER_CONTENT_TYPES = {"call_offer"}


async def fan_out_message(db: AsyncSession, conversation: Conversation, message) -> None:
    envelope = _envelope_from_message(conversation.id, message)
    is_call_offer = message.content_type in _CALL_OFFER_CONTENT_TYPES

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
            local_channel = await _deliver_locally(db, p.user_id, envelope)
            delivered_online = local_channel in ("online", "mixed")
            # Входящий звонок — оффлайн получатель: пробудить через push
            if not delivered_online and is_call_offer:
                # call_id хранится в envelope (клиент кладёт в ciphertext, но
                # packet_id достаточен для wakeup — клиент найдёт звонок по WS)
                import asyncio
                asyncio.create_task(notify_incoming_call(
                    callee_user_id=p.user_id,
                    call_id=message.id,
                ))
            elif not delivered_online:
                import asyncio
                asyncio.create_task(notify_new_message(recipient_user_id=p.user_id))
            continue

        home_node_url = await resolve_home_node(p.user_id)
        if home_node_url and home_node_url != settings.public_url:
            remote_targets.setdefault(home_node_url, []).append(p.user_id)
        # else: unknown participant — nothing we can do for them in MVP.

    if remote_targets:
        # Hop-scoped meta (R5): only sender + recipients on that Home — not the
        # full participant roster — so Relay/peer see less of the social graph.
        for home_node_url, target_user_ids in remote_targets.items():
            conversation_meta = {
                "conversation_id": conversation.id,
                "type": conversation.type,
                "name": conversation.name,
                "participant_user_ids": list({message.sender_user_id, *target_user_ids}),
            }
            try:
                await deliver_to_remote_home_node(home_node_url, envelope, conversation_meta)
            except Exception as e:
                # Non-fatal for the sender's own request (already 200'd). Instead
                # of only logging, durably enqueue for background retry — see
                # docs/reality/R3-message-lifecycle.md Gaps ("Post-R5 durable
                # outbox") and spec/0202_DELIVERY.md queue policy.
                logger.warning(
                    "Federation delivery to %s failed for conversation %s, enqueuing outbox retry: %s",
                    home_node_url, conversation.id, e,
                )
                for target_user_id in target_user_ids:
                    await enqueue_outbox(
                        db,
                        packet_id=message.id,
                        target_user_id=target_user_id,
                        target_home_url=home_node_url,
                        envelope=envelope,
                        conversation_meta=conversation_meta,
                        last_error=str(e),
                    )

    # Mirror only the sender-specific envelopes to the sender's other devices.
    # Broadcasting the recipient ciphertext here made linked devices receive
    # an undecryptable shell (or the literal "...").
    try:
        await _deliver_locally(
            db,
            message.sender_user_id,
            envelope,
            exclude_device_id=message.sender_device_id,
        )
    except Exception as exc:
        # Mirroring to the sender's other devices is best-effort. The message
        # has already been committed and recipient delivery must not turn into
        # HTTP 500 merely because an optional offline mailbox is unavailable.
        logger.warning(
            "Sender-device mirror failed for message %s: %s",
            message.id,
            exc,
        )


async def upsert_conversation_mirror(db: AsyncSession, conversation_meta: dict) -> Conversation:
    """Called by /internal/deliver when this Home Node first sees a
    federated Conversation it wasn't the origin of.

    This function deliberately does not commit. The receiver persists mirror
    metadata and the packet in one atomic transaction, avoiding two SQLite
    fsync boundaries on every federated message.
    """
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
    await db.flush()
    return conv


async def push_home_changed_to_local_contacts(
    db: AsyncSession,
    *,
    changed_user_id: str,
    home_node_url: str,
    home_updated_at: Optional[str],
) -> set[str]:
    """Push WS `home_changed` to every locally-hosted user who shares a
    Conversation with changed_user_id — used both by the Home where the
    change was detected (for its local peers) and by
    /internal/home-changed on a peer Home receiving the federation notify.
    Returns every *other* participant user_id (local + remote) found, so a
    caller can also fan the notify out to remote peers' Home Nodes."""
    result = await db.execute(
        select(ConversationParticipant.conversation_id).where(ConversationParticipant.user_id == changed_user_id)
    )
    conversation_ids = {row[0] for row in result.all()}
    if not conversation_ids:
        return set()

    result = await db.execute(
        select(ConversationParticipant.user_id)
        .where(ConversationParticipant.conversation_id.in_(conversation_ids))
        .where(ConversationParticipant.user_id != changed_user_id)
    )
    peer_user_ids = {row[0] for row in result.all()}

    ws_payload = {
        "type": "home_changed",
        "user_id": changed_user_id,
        "home_node_url": home_node_url,
        "home_updated_at": home_updated_at,
    }
    for peer_id in peer_user_ids:
        if await db.get(User, peer_id):
            await manager.send_to_user(peer_id, ws_payload)

    return peer_user_ids


async def notify_contacts_of_home_change(
    db: AsyncSession,
    *,
    user_id: str,
    home_node_url: str,
    home_updated_at: Optional[str],
) -> None:
    """Post-R5 CONTROL notify (docs/reality/R4-routing.md Gaps "Нет notify
    смены Home"): called right after this node detects it just became the
    new home for user_id (see app/discovery_publish.py). Best-effort only —
    peers still self-heal on their next live resolve either way."""
    peer_user_ids = await push_home_changed_to_local_contacts(
        db,
        changed_user_id=user_id,
        home_node_url=home_node_url,
        home_updated_at=home_updated_at,
    )

    remote_home_urls: set[str] = set()
    for peer_id in peer_user_ids:
        if await db.get(User, peer_id):
            continue  # already handled above via local WS push
        peer_home_url = await resolve_home_node(peer_id)
        if peer_home_url and peer_home_url != settings.public_url:
            remote_home_urls.add(peer_home_url)

    for peer_home_url in remote_home_urls:
        try:
            await notify_remote_home_changed(
                peer_home_url,
                user_id=user_id,
                new_home_node_url=home_node_url,
                home_updated_at=home_updated_at,
            )
        except Exception as e:
            logger.warning(
                "home_changed notify to %s failed for user %s: %s", peer_home_url, user_id, e
            )


async def deliver_locally_for_federated_message(
    db: AsyncSession, conversation_meta: dict, envelope: dict
) -> FederatedHomeAcceptance:
    acceptance = FederatedHomeAcceptance()
    online = mailbox = ignored = 0
    for uid in conversation_meta["participant_user_ids"]:
        if uid == envelope["sender_user_id"]:
            continue
        local_user = await db.get(User, uid)
        if not local_user:
            continue
        channel = await _deliver_locally(db, uid, envelope)
        if channel == "online":
            online += 1
        elif channel == "mixed":
            online += 1
            mailbox += 1
        elif channel == "mailbox":
            mailbox += 1
        else:
            ignored += 1
    return FederatedHomeAcceptance(
        online_recipients=online,
        mailbox_recipients=mailbox,
        ignored_recipients=ignored,
    )


async def upsert_delivery_ack(
    db: AsyncSession,
    *,
    packet_id: str,
    conversation_id: str,
    from_user_id: str,
    from_device_id: str = "",
) -> tuple[datetime, bool]:
    """Idempotently persist one authenticated endpoint acknowledgement."""
    result = await db.execute(
        select(MessageDeliveryAck).where(
            MessageDeliveryAck.packet_id == packet_id,
            MessageDeliveryAck.from_user_id == from_user_id,
            MessageDeliveryAck.from_device_id == from_device_id,
        )
    )
    row = result.scalar_one_or_none()
    if row:
        return row.acked_at, False

    ack = MessageDeliveryAck(
        packet_id=packet_id,
        conversation_id=conversation_id,
        from_user_id=from_user_id,
        from_device_id=from_device_id,
    )
    db.add(ack)
    try:
        await db.commit()
    except IntegrityError:
        # Concurrent ack from the same user raced us — fall back to the row
        # the other request just committed instead of erroring.
        await db.rollback()
        result = await db.execute(
            select(MessageDeliveryAck).where(
                MessageDeliveryAck.packet_id == packet_id,
                MessageDeliveryAck.from_user_id == from_user_id,
                MessageDeliveryAck.from_device_id == from_device_id,
            )
        )
        row = result.scalar_one_or_none()
        if row:
            return row.acked_at, False
        raise
    await db.refresh(ack)
    return ack.acked_at, True


async def delivery_ack_complete(
    db: AsyncSession,
    *,
    message: Message,
) -> bool:
    """Whether every endpoint in the immutable delivery snapshot ACKed."""
    target_devices = {
        value
        for value in (message.delivery_target_device_ids or [])
        if isinstance(value, str) and value
    }
    if target_devices:
        ack_result = await db.execute(
            select(MessageDeliveryAck.from_device_id).where(
                MessageDeliveryAck.packet_id == message.id,
                MessageDeliveryAck.from_device_id.in_(target_devices),
            )
        )
        acknowledged_devices = {row[0] for row in ack_result.all()}
        return target_devices.issubset(acknowledged_devices)

    participant_result = await db.execute(
        select(ConversationParticipant.user_id).where(
            ConversationParticipant.conversation_id == message.conversation_id,
            ConversationParticipant.user_id != message.sender_user_id,
        )
    )
    expected_users = {row[0] for row in participant_result.all()}
    if not expected_users:
        return False
    ack_result = await db.execute(
        select(MessageDeliveryAck.from_user_id).where(
            MessageDeliveryAck.packet_id == message.id,
            MessageDeliveryAck.from_user_id.in_(expected_users),
        )
    )
    acknowledged_users = {row[0] for row in ack_result.all()}
    return expected_users.issubset(acknowledged_users)


async def user_delivery_ack_complete(
    db: AsyncSession,
    *,
    message: Message,
    user_id: str,
) -> bool:
    """Whether this user's targeted device copies may leave the mailbox."""
    target_devices = {
        value
        for value in (message.delivery_target_device_ids or [])
        if isinstance(value, str) and value
    }
    if not target_devices:
        return True
    owned_result = await db.execute(
        select(Device.id).where(
            Device.user_id == user_id,
            Device.id.in_(target_devices),
        )
    )
    expected = {row[0] for row in owned_result.all()}
    if not expected:
        return False
    ack_result = await db.execute(
        select(MessageDeliveryAck.from_device_id).where(
            MessageDeliveryAck.packet_id == message.id,
            MessageDeliveryAck.from_user_id == user_id,
            MessageDeliveryAck.from_device_id.in_(expected),
        )
    )
    acknowledged = {row[0] for row in ack_result.all()}
    return expected.issubset(acknowledged)


async def purge_message_after_full_delivery(
    db: AsyncSession,
    *,
    message: Message,
) -> bool:
    """Delete the transient Home copy after every recipient has ACKed.

    For a direct conversation this is the single recipient. For a group the
    sender Home waits for every non-sender participant represented in its
    conversation mirror. Recipient Homes receive only their local target set,
    so they independently release their own temporary copy after those local
    recipients ACK. Endpoint history is unaffected.
    """
    if not await delivery_ack_complete(db, message=message):
        return False
    await db.delete(message)
    await db.commit()
    return True


async def handle_delivery_ack(
    db: AsyncSession,
    *,
    message: Message,
    from_user_id: str,
    from_device_id: str,
    acked_at: datetime,
    delivery_complete: bool,
) -> None:
    """Post-R5 e2e delivery ACK (spec/0202_DELIVERY.md): notify
    message.sender_user_id that from_user_id ack'd message.id — WS push if
    the sender is hosted locally, else forward across federation to
    whichever Home currently hosts them. A remote failure is deliberately
    propagated: the recipient Home must retain its transient Message/mailbox
    evidence so the endpoint can retry instead of silently losing the ACK."""
    ws_payload = {
        "type": "delivery_ack",
        "packet_id": message.id,
        "conversation_id": message.conversation_id,
        "from_user_id": from_user_id,
        "from_device_id": from_device_id,
        "delivery_complete": delivery_complete,
        "acked_at": acked_at.replace(tzinfo=timezone.utc).isoformat(),
    }

    if delivery_complete and (message.delivery_status or "sent") == "sent":
        message.delivery_status = "delivered"
        message.delivered_at = acked_at.replace(tzinfo=None)
        await db.commit()
        from app.federation import record_delivery_completed
        record_delivery_completed()

    sender = await db.get(User, message.sender_user_id)
    if sender:
        if delivery_complete:
            await manager.send_to_user(message.sender_user_id, ws_payload)
        return

    home_node_url = await resolve_home_node(message.sender_user_id)
    if not home_node_url or home_node_url == settings.public_url:
        raise RuntimeError("sender Home is unavailable for delivery ACK")
    try:
        await notify_remote_delivery_ack(
            home_node_url,
            packet_id=message.id,
            conversation_id=message.conversation_id,
            from_user_id=from_user_id,
            from_device_id=from_device_id,
            acked_at=ws_payload["acked_at"],
        )
    except Exception as e:
        logger.warning(
            "delivery_ack notify to %s failed for packet %s: %s", home_node_url, message.id, e
        )
        raise RuntimeError("delivery ACK forwarding failed") from e
