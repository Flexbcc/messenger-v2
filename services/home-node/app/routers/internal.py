from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import get_db
from app.fanout import deliver_locally_for_federated_message, upsert_conversation_mirror
from app.fed_security import FederationAuthDep, get_federation_security
from app.models import Message
from app.schemas import InternalDeliverRequest
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
        if payload.origin_node_id != verified_origin:
            raise HTTPException(status_code=403, detail="origin_node_id does not match federation signature")

    fs = get_federation_security()
    await verify_incoming_federation(
        federation=payload.federation,
        envelope=payload.envelope,
        endpoint="/internal/deliver",
        trust_cache=fs.trust_cache,
        nonce_store=fs.nonce_store,
        audit=fs.audit_log,
        expected_origin_node_id=payload.origin_node_id,
    )

    conv = await upsert_conversation_mirror(db, payload.conversation_meta)

    envelope = payload.envelope
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
        )
        db.add(message)
        await db.commit()

    await deliver_locally_for_federated_message(db, payload.conversation_meta, envelope)
    return {"status": "delivered"}
