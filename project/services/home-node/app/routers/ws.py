"""
Realtime push channel. Sending happens over REST (/conversations/{id}/messages)
— the WebSocket is receive-only, matching the pattern in
~/secret_room/backend/app/websocket (ADR-0005). Token is passed as a query
param because browser WebSocket clients cannot set custom headers.
"""
from fastapi import APIRouter, Query, WebSocket, WebSocketDisconnect

from app.federation import drain_buffer
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
    await manager.connect(user_id, websocket)

    # Drain anything buffered while this user's devices were all offline.
    for envelope in await drain_buffer(user_id):
        await manager.send_to_user(user_id, {"type": "new_message", "message": envelope})

    try:
        while True:
            # Client doesn't send anything meaningful over this channel in
            # MVP; we just wait for disconnect. Receiving keeps the socket
            # alive and lets us detect the client going away.
            await websocket.receive_text()
    except WebSocketDisconnect:
        manager.disconnect(user_id, websocket)
