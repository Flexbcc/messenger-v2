"""
Realtime push channel. Sending happens over REST (/conversations/{id}/messages)
— the WebSocket is receive-only, matching the pattern in
~/secret_room/backend/app/websocket (ADR-0005). Token is passed as a query
param because browser WebSocket clients cannot set custom headers.
"""
import json
import time
from datetime import datetime

from fastapi import APIRouter, Query, WebSocket, WebSocketDisconnect
from sqlalchemy import select

from app.db import async_session
from app.federation import drain_buffer
from app.models import ConversationParticipant, Device
from app.security import is_token_revoked, verify_token
from app.ws import manager

router = APIRouter(tags=["realtime"])


async def _touch_device(device_id: str) -> None:
    if not device_id:
        return
    async with async_session() as db:
        device = await db.get(Device, device_id)
        if device:
            device.last_active = datetime.utcnow()
            await db.commit()


@router.websocket("/ws")
async def websocket_endpoint(websocket: WebSocket, token: str = Query(...)):
    payload = verify_token(token)
    if not payload:
        await websocket.close(code=4401)
        return

    user_id = payload.get("sub")
    device_id = payload.get("device_id")
    if not isinstance(user_id, str) or not isinstance(device_id, str):
        await websocket.close(code=4401)
        return
    async with async_session() as db:
        jti = payload.get("jti")
        if jti and await is_token_revoked(db, jti):
            await websocket.close(code=4401)
            return
        device = await db.get(Device, device_id)
        if device is None or device.user_id != user_id:
            await websocket.close(code=4401)
            return
        if not device.trusted:
            await websocket.close(code=4403)
            return
    await _touch_device(device_id)
    if not await manager.connect(user_id, device_id, websocket):
        return

    # Drain anything buffered while this user's devices were all offline.
    # Push first, delete only on success, so a failed send leaves the entry
    # buffered for the next reconnect instead of losing it.
    async def _push_buffered(envelope: dict) -> bool:
        outbound = envelope
        device_envelopes = envelope.get("device_envelopes")
        if isinstance(device_envelopes, list):
            targeted = next(
                (
                    item
                    for item in device_envelopes
                    if isinstance(item, dict)
                    and item.get("device_id") == device_id
                    and isinstance(item.get("ciphertext"), str)
                ),
                None,
            )
            if targeted is None:
                # Keep the mailbox entry: another registered device may be its
                # intended recipient, and deleting here would lose that copy.
                return False
            outbound = {**envelope, "ciphertext": targeted["ciphertext"]}
            outbound.pop("device_envelopes", None)
        return await manager.send_to_device(
            device_id, {"type": "new_message", "message": outbound}
        )

    await drain_buffer(user_id, _push_buffered)

    last_typing_at = 0.0
    try:
        while True:
            raw = await websocket.receive_text()
            if len(raw.encode("utf-8")) > 4096:
                await websocket.close(code=4400, reason="message too large")
                break
            try:
                msg = json.loads(raw)
            except Exception:
                continue

            if not isinstance(msg, dict):
                continue

            msg_type = msg.get("type")

            if msg_type == "typing":
                conv_id = msg.get("conversation_id")
                now = time.monotonic()
                if (
                    isinstance(conv_id, str)
                    and 0 < len(conv_id) <= 128
                    and now - last_typing_at >= 0.25
                ):
                    # Look up conversation participants from DB and fan out.
                    async with async_session() as db:
                        result = await db.execute(
                            select(ConversationParticipant.user_id).where(
                                ConversationParticipant.conversation_id == conv_id
                            )
                        )
                        participant_ids = [row[0] for row in result.all()]
                    if user_id not in participant_ids:
                        continue
                    last_typing_at = now
                    payload = {
                        "type": "typing",
                        "from_user_id": user_id,
                        "conversation_id": conv_id,
                    }
                    for pid in participant_ids:
                        if pid != user_id:
                            await manager.send_to_user(pid, payload)

            # ping/pong keepalive (some proxies need periodic traffic)
            elif msg_type == "ping":
                await websocket.send_text(json.dumps({"type": "pong"}))

    except WebSocketDisconnect:
        await _touch_device(device_id)
        manager.disconnect(websocket)
