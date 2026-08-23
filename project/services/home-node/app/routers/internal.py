from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import settings
from app.db import get_db
from app.disappearing import apply_ttl_to_message
from app.fanout import (
    deliver_locally_for_federated_message,
    push_home_changed_to_local_contacts,
    upsert_conversation_mirror,
)
from app.fed_security import FederationAuthDep, get_federation_security
from shared.security.sealed_sender import unseal_sender
from app.models import FederatedMediaRef, Message, User
from app.schemas import HomeChangedRequest, InternalDeliverRequest, InternalDeliveryAckRequest
from app.storage_policy import build_media_user_profile, build_storage_policy_summary
from app.ws import manager
from shared.security.config import INTERNAL_SECURITY_MODE
from shared.security.envelope_verify import verify_incoming_federation

router = APIRouter(prefix="/internal", tags=["federation"])


@router.post("/deliver")
async def deliver(
    payload: InternalDeliverRequest,
    db: AsyncSession = Depends(get_db),
    verified_origin: str = FederationAuthDep,
):
    if INTERNAL_SECURITY_MODE == "signed" and verified_origin != "legacy":
        expected_transport_origin = payload.forwarded_by_node_id or payload.origin_node_id
        if expected_transport_origin != verified_origin:
            raise HTTPException(
                status_code=403,
                detail="transport origin does not match federation request signature",
            )

    fs = get_federation_security()
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

    conv = await upsert_conversation_mirror(db, payload.conversation_meta)

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
    existing = await db.get(Message, envelope["packet_id"])
    if not existing:
        message = Message(
            id=envelope["packet_id"],
            conversation_id=conv.id,
            sender_user_id=envelope["sender_user_id"],
            sender_device_id=envelope.get("sender_device_id"),
            ciphertext=envelope["ciphertext"],
            content_type=envelope.get("content_type", "text"),
            crypto_version=envelope.get("crypto_version", "signal-v1"),
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
        await db.commit()

    await deliver_locally_for_federated_message(db, payload.conversation_meta, envelope)
    return {"status": "delivered"}


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
    sender_user_id = message.sender_user_id if message else None
    if sender_user_id and await db.get(User, sender_user_id):
        await manager.send_to_user(
            sender_user_id,
            {
                "type": "delivery_ack",
                "packet_id": payload.packet_id,
                "conversation_id": payload.conversation_id,
                "from_user_id": payload.from_user_id,
                "acked_at": payload.acked_at,
            },
        )
    return {"status": "ok"}


@router.get("/users/{user_id}/storage-profile")
async def user_storage_profile(user_id: str, db: AsyncSession = Depends(get_db)):
    """
    Media-node (federation) reads per-user storage policy derived from
    profile_settings.storage_ownership catalog values.
    """
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
