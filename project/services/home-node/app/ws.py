"""
Realtime delivery to connected Client devices. Adapted from the
ConnectionManager pattern in ~/secret_room/backend/app/websocket/manager.py
(ADR-0005), simplified to key by user_id rather than per-device (see
app/fanout.py for the same MVP simplification).
"""
from fastapi import WebSocket


class ConnectionManager:
    def __init__(self):
        self.active: dict[str, set[WebSocket]] = {}

    async def connect(self, user_id: str, ws: WebSocket) -> None:
        await ws.accept()
        self.active.setdefault(user_id, set()).add(ws)

    def disconnect(self, user_id: str, ws: WebSocket) -> None:
        conns = self.active.get(user_id)
        if conns and ws in conns:
            conns.discard(ws)
            if not conns:
                del self.active[user_id]

    def is_online(self, user_id: str) -> bool:
        return bool(self.active.get(user_id))

    async def send_to_user(self, user_id: str, payload: dict) -> bool:
        """Returns True if delivered to at least one connection."""
        conns = self.active.get(user_id)
        if not conns:
            return False
        dead = []
        for ws in conns:
            try:
                await ws.send_json(payload)
            except Exception:
                dead.append(ws)
        for ws in dead:
            conns.discard(ws)
        return len(conns) > 0


manager = ConnectionManager()
