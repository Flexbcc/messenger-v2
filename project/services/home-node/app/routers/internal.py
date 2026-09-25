import hmac
import time
from datetime import datetime

from fastapi import APIRouter, Depends, Header, HTTPException, Response
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import settings
from app.db import get_db
from app.disappearing import apply_ttl_to_message
from app.delivery_metrics import record_delivery_stage
from app.fanout import (
    delivery_ack_complete,
    delivery_target_snapshot,
    deliver_locally_for_federated_message,
    purge_message_after_full_delivery,
    push_home_changed_to_local_contacts,
    upsert_delivery_ack,
    upsert_conversation_mirror,
)
from app.federation import resolve_home_node
from app.federation import record_device_ack
from app.fed_security import FederationAuthDep, get_federation_security
from shared.security.sealed_sender import unseal_sender
from app.models import (
    FederatedMediaRef,
    Message,
    MessageDeliveryAck,
    MessageMediaRef,
    User,
)
from app.schemas import HomeChangedRequest, InternalDeliverRequest, InternalDeliveryAckRequest
from app.storage_policy import build_media_user_profile, build_storage_policy_summary
from app.ws import manager
from shared.security.config import INTERNAL_SECURITY_MODE
from shared.security.envelope_verify import verify_incoming_federation

router = APIRouter(prefix="/internal", tags=["federation"])


def _same_endpoint(left: object, right: object) -> bool:
    return (
        isinstance(left, str)
        and isinstance(right, str)
        and left.rstrip("/") == right.rstrip("/")
    )


async def _validate_federated_delivery_identity(
    db: AsyncSession,
    *,
    origin_node_id: str,
    envelope: dict,
    conversation_meta: dict,
) -> None:
    sender_user_id = envelope.get("sender_user_id")
    if not sender_user_id:
        raise HTTPException(status_code=400, detail="sender identity is unavailable")
    if sender_user_id not in conversation_meta["participant_user_ids"]:
        raise HTTPException(
            status_code=400,
            detail="sender is not a conversation participant",
        )
    if await db.get(User, sender_user_id):
        raise HTTPException(
            status_code=403,
            detail="a federated delivery cannot impersonate a local user",
        )

    fs = get_federation_security()
    origin_node = await fs.trust_cache.get_node(origin_node_id)
    origin_url = origin_node.get("node_url") if origin_node else None
    sender_home_url = await resolve_home_node(sender_user_id)
    if not _same_endpoint(origin_url, sender_home_url):
        raise HTTPException(
            status_code=403,
            detail="sender is not hosted by the federation origin",
        )

    media_node_url = envelope.get("media_node_url")
    if media_node_url and not await fs.trust_cache.trusted_node_for_url(
        media_node_url,
        capability="media",
    ):
        raise HTTPException(
            status_code=403,
            detail="media origin is not a trusted Media node",
        )

    recipient_ids = [
        user_id
        for user_id in conversation_meta["participant_user_ids"]
        if user_id != sender_user_id
    ]
    has_local_recipient = False
    for user_id in recipient_ids:
        if await db.get(User, user_id):
            has_local_recipient = True
            break
    if not has_local_recipient:
        raise HTTPException(
            status_code=400,
            detail="delivery has no recipient hosted on this Home node",
        )


@router.post("/deliver")
async def deliver(
    payload: InternalDeliverRequest,
    db: AsyncSession = Depends(get_db),
    verified_origin: str = FederationAuthDep,
):
    request_started = time.perf_counter()
    if INTERNAL_SECURITY_MODE == "signed" and verified_origin != "legacy":
        expected_transport_origin = payload.forwarded_by_node_id or payload.origin_node_id
        if expected_transport_origin != verified_origin:
            raise HTTPException(
                status_code=403,
                detail="transport origin does not match federation request signature",
            )

    fs = get_federation_security()
    verify_started = time.perf_counter()
    await verify_incoming_federation(
        federation=payload.federation,
        envelope=payload.envelope,
        endpoint="/internal/deliver",
        trust_cache=fs.trust_cache,
        nonce_store=fs.nonce_store,
        audit=fs.audit_log,
        expected_origin_node_id=payload.origin_node_id,
        conversation_meta=payload.conversation_meta,
        expected_target_node_id=settings.public_url,
        expected_routes={"direct", "relay"},
    )
    record_delivery_stage(
        "receiver_envelope_verify", (time.perf_counter() - verify_started) * 1000
    )

    if INTERNAL_SECURITY_MODE == "signed":
        federation = payload.federation or {}
        if federation.get("sender_user_id", "") != payload.envelope.get(
            "sender_user_id", ""
        ):
            raise HTTPException(
                status_code=400,
                detail="federation sender metadata does not match envelope",
            )
        if federation.get("conversation_id") != payload.conversation_meta[
            "conversation_id"
        ]:
            raise HTTPException(
                status_code=400,
                detail="federation conversation metadata does not match payload",
            )

    envelope = payload.envelope

    # Sealed sender (Task #68): если envelope содержит sealed_sender_box,
    # расшифровываем его нашим curve private key и восстанавливаем sender_user_id.
    # Если расшифровка не удалась (например, старый отправитель без sealed sender)
    # — продолжаем с тем что есть (обратная совместимость).
    sealed_box = envelope.get("sealed_sender_box")
    if sealed_box and not envelope.get("sender_user_id"):
        fs = get_federation_security()
        curve_pk = fs.curve_private_key
        if curve_pk:
            decrypted_sender = unseal_sender(sealed_box, curve_pk)
            if decrypted_sender:
                envelope = dict(envelope)
                envelope["sender_user_id"] = decrypted_sender
                envelope.pop("sealed_sender_box", None)
            else:
                import logging as _logging
                _logging.getLogger(__name__).warning(
                    "Failed to unseal sender_user_id from sealed_sender_box"
                )
                raise HTTPException(
                    status_code=400,
                    detail="sealed sender identity could not be decrypted",
                )

    identity_started = time.perf_counter()
    await _validate_federated_delivery_identity(
        db,
        origin_node_id=payload.origin_node_id,
        envelope=envelope,
        conversation_meta=payload.conversation_meta,
    )
    record_delivery_stage(
        "receiver_identity_verify", (time.perf_counter() - identity_started) * 1000
    )
    db_started = time.perf_counter()
    conv = await upsert_conversation_mirror(db, payload.conversation_meta)
    existing = await db.get(Message, envelope["packet_id"])
    if not existing:
        local_target_users: set[str] = set()
        for user_id in payload.conversation_meta["participant_user_ids"]:
            if user_id == envelope["sender_user_id"]:
                continue
            if await db.get(User, user_id) is not None:
                local_target_users.add(user_id)
        target_device_ids = await delivery_target_snapshot(
            db,
            device_envelopes=envelope.get("device_envelopes"),
            local_user_ids=local_target_users,
        )
        message = Message(
            id=envelope["packet_id"],
            conversation_id=conv.id,
            sender_user_id=envelope["sender_user_id"],
            sender_device_id=envelope.get("sender_device_id"),
            device_envelopes=envelope.get("device_envelopes"),
            delivery_target_device_ids=target_device_ids,
            ciphertext=envelope["ciphertext"],
            content_type=envelope.get("content_type", "text"),
            crypto_version=envelope.get("crypto_version", "signal-v1"),
            media_ids=envelope.get("media_ids"),
            # Storage federation (Task #63): URL Media-node отправителя
            origin_media_node_url=envelope.get("media_node_url"),
        )
        db.add(message)
        # Исчезающие сообщения (Task #70): применить TTL если разговор настроен
        await apply_ttl_to_message(message, conv)
        # Storage federation (Task #63): сохраняем маппинг media_id → origin Media-node
        media_node_url = envelope.get("media_node_url")
        media_ids = envelope.get("media_ids") or []
        if media_node_url and media_ids:
            for mid in media_ids:
                existing_ref = await db.get(FederatedMediaRef, mid)
                if not existing_ref:
                    db.add(FederatedMediaRef(media_id=mid, origin_media_node_url=media_node_url))
                db.add(
                    MessageMediaRef(
                        media_id=mid,
                        message_id=message.id,
                        conversation_id=conv.id,
                    )
                )
    # Mirror metadata and the packet share one durability boundary. Commit is
    # still required for duplicate packets because participant metadata may
    # have been completed by upsert_conversation_mirror.
    await db.commit()
    record_delivery_stage(
        "receiver_db_commit", (time.perf_counter() - db_started) * 1000
    )

    websocket_started = time.perf_counter()
    acceptance = await deliver_locally_for_federated_message(
        db, payload.conversation_meta, envelope
    )
    record_delivery_stage(
        "receiver_ws_delivery", (time.perf_counter() - websocket_started) * 1000
    )
    record_delivery_stage("receiver_total", (time.perf_counter() - request_started) * 1000)
    if acceptance.online_recipients + acceptance.mailbox_recipients == 0:
        raise HTTPException(
            status_code=409,
            detail="target Home has no deliverable local recipient",
        )
    return {
        "status": "home_accepted",
        "acceptance": acceptance.disposition,
        "online_recipients": acceptance.online_recipients,
        "mailbox_recipients": acceptance.mailbox_recipients,
        "device_acknowledged": False,
    }


@router.post("/home-changed")
async def home_changed(
    payload: HomeChangedRequest,
    db: AsyncSession = Depends(get_db),
    verified_origin: str = FederationAuthDep,
):
    """Post-R5 CONTROL notify receiver (docs/reality/R4-routing.md Gaps "Нет
    notify смены Home"): a peer Home tells us user_id's home moved. No chat
    ciphertext involved — the `envelope` field only exists so the existing
    federation signature/replay verification applies. Pushes WS
    `home_changed` to whichever of our local users share a Conversation
    with that user_id, so they can refresh Discovery on their end."""
    if INTERNAL_SECURITY_MODE == "signed" and verified_origin != "legacy":
        if payload.origin_node_id != verified_origin:
            raise HTTPException(status_code=403, detail="origin_node_id does not match federation signature")

    fs = get_federation_security()
    await verify_incoming_federation(
        federation=payload.federation,
        envelope=payload.envelope,
        endpoint="/internal/home-changed",
        trust_cache=fs.trust_cache,
        nonce_store=fs.nonce_store,
        audit=fs.audit_log,
        expected_origin_node_id=payload.origin_node_id,
        expected_target_node_id=settings.public_url,
        expected_recipient_user_id=payload.user_id,
        expected_routes={"control"},
    )

    await push_home_changed_to_local_contacts(
        db,
        changed_user_id=payload.user_id,
        home_node_url=payload.home_node_url,
        home_updated_at=payload.home_updated_at,
    )
    return {"status": "ok"}


@router.post("/delivery-ack")
async def delivery_ack(
    payload: InternalDeliveryAckRequest,
    db: AsyncSession = Depends(get_db),
    verified_origin: str = FederationAuthDep,
):
    """Post-R5 semantic e2e delivery ACK (spec/0202_DELIVERY.md), peer side:
    a recipient's Home forwards from_user_id's ack of packet_id here because
    the sender is hosted on this node. `packet_id` == Message.id, and since
    this is the sender's own Home it already has that Message row (created
    by send_message) — used to find sender_user_id for the WS push, same
    lookup pattern as /deliver."""
    if INTERNAL_SECURITY_MODE == "signed" and verified_origin != "legacy":
        if payload.origin_node_id != verified_origin:
            raise HTTPException(status_code=403, detail="origin_node_id does not match federation signature")

    fs = get_federation_security()
    await verify_incoming_federation(
        federation=payload.federation,
        envelope=payload.envelope,
        endpoint="/internal/delivery-ack",
        trust_cache=fs.trust_cache,
        nonce_store=fs.nonce_store,
        audit=fs.audit_log,
        expected_origin_node_id=payload.origin_node_id,
        expected_target_node_id=settings.public_url,
        expected_recipient_user_id=payload.from_user_id,
        expected_routes={"control"},
    )

    message = await db.get(Message, payload.packet_id)
    ack_device_id = payload.from_device_id if payload.from_device_id else ""
    if message is None:
        previous_ack = await db.execute(
            select(MessageDeliveryAck.id).where(
                MessageDeliveryAck.packet_id == payload.packet_id,
                MessageDeliveryAck.conversation_id == payload.conversation_id,
                MessageDeliveryAck.from_user_id == payload.from_user_id,
                MessageDeliveryAck.from_device_id == ack_device_id,
            )
        )
        if previous_ack.scalar_one_or_none():
            return {"status": "ok", "duplicate": True}
        raise HTTPException(status_code=404, detail="Message not found")
    sender_user_id = message.sender_user_id if message else None
    if message and message.delivery_target_device_ids:
        if payload.from_device_id not in set(message.delivery_target_device_ids):
            raise HTTPException(status_code=403, detail="ACK device is not a delivery target")
    _stored_at, ack_created = await upsert_delivery_ack(
        db,
        packet_id=payload.packet_id,
        conversation_id=payload.conversation_id,
        from_user_id=payload.from_user_id,
        from_device_id=(
            payload.from_device_id if message.delivery_target_device_ids else ""
        ),
    )
    if ack_created:
        record_device_ack()
    complete = bool(message) and await delivery_ack_complete(db, message=message)
    if message and complete and (message.delivery_status or "sent") == "sent":
        acked_at = datetime.fromisoformat(payload.acked_at.replace("Z", "+00:00"))
        message.delivery_status = "delivered"
        message.delivered_at = acked_at.replace(tzinfo=None)
        await db.commit()
        from app.federation import record_delivery_completed
        record_delivery_completed()
    if complete and sender_user_id and await db.get(User, sender_user_id):
        await manager.send_to_user(
            sender_user_id,
            {
                "type": "delivery_ack",
                "packet_id": payload.packet_id,
                "conversation_id": payload.conversation_id,
                "from_user_id": payload.from_user_id,
                "from_device_id": payload.from_device_id,
                "delivery_complete": True,
                "acked_at": payload.acked_at,
            },
        )
    if message:
        await purge_message_after_full_delivery(db, message=message)
    return {"status": "ok"}


@router.get("/users/{user_id}/storage-profile")
async def user_storage_profile(
    user_id: str,
    response: Response,
    media_access_secret: str | None = Header(
        default=None,
        alias="X-Media-Access-Secret",
    ),
    db: AsyncSession = Depends(get_db),
):
    """
    Media-node (federation) reads per-user storage policy derived from
    profile_settings.storage_ownership catalog values.
    """
    expected_secret = settings.media_access_secret
    if (
        not expected_secret
        or not media_access_secret
        or not hmac.compare_digest(media_access_secret, expected_secret)
    ):
        raise HTTPException(status_code=403, detail="Media node authentication required")
    response.headers["Cache-Control"] = "no-store"
    response.headers["Pragma"] = "no-cache"
    user = await db.get(User, user_id)
    if not user:
        raise HTTPException(status_code=404, detail="User not found")
    profile = build_media_user_profile(
        user_id,
        user.profile_settings,
        default_relay_url=settings.public_url,
    )
    return {
        "user_id": user_id,
        "profile": profile,
        "policy": build_storage_policy_summary(user.profile_settings),
    }
