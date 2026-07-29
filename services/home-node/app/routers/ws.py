"""
Realtime push channel. Sending happens over REST (/conversations/{id}/messages)
— the WebSocket is receive-only, matching the pattern in
~/secret_room/backend/app/websocket (ADR-0005). Token is passed as a query
param because browser WebSocket clients cannot set custom headers.
"""
import json

from fastapi import APIRouter, Query, WebSocket, WebSocketDisconnect
from sqlalchemy import select

from app.db import async_session
from app.federation import drain_buffer
from app.models import ConversationParticipant
from app.security import verify_token
from app.ws import manager

router = APIRouter(tags=["realtime"])


@router.websocket("/ws")
async def websocket_endpoint(websocket: WebSocket, token: str = Query(...)):
    payload = verify_token(token)
    if not payload:
        await websocket.close(code=4401)
        return

    user_id = payload["sub"]
    device_id = payload.get("device_id", "")
    await manager.connect(user_id, device_id, websocket)

    # Drain anything buffered while this user's devices were all offline.
    # Push first, delete only on success, so a failed send leaves the entry
    # buffered for the next reconnect instead of losing it.
    async def _push_buffered(envelope: dict) -> bool:
        return await manager.send_to_user(user_id, {"type": "new_message", "message": envelope})

    await drain_buffer(user_id, _push_buffered)

    try:
        while True:
            raw = await websocket.receive_text()
            try:
                msg = json.loads(raw)
            except Exception:
                continue

            msg_type = msg.get("type")

            if msg_type == "typing":
                conv_id = msg.get("conversation_id")
                if conv_id:
                    # Look up conversation participants from DB and fan out.
                    async with async_session() as db:
                        result = await db.execute(
                            select(ConversationParticipant.user_id).where(
                                ConversationParticipant.conversation_id == conv_id
                            )
                        )
                        participant_ids = [row[0] for row in result.all()]
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
        manager.disconnect(user_id, websocket)
