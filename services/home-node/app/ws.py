"""
Realtime delivery to connected Client devices.

Per-device tracking (Task #57 / spec/0102_DATA_FLOW.md):
  active_by_device: dict[device_id, WebSocket]  — canonical lookup
  active: dict[user_id, set[WebSocket]]          — kept for broadcast/is_online
  _device_of: dict[WebSocket, device_id]         — reverse lookup for disconnect

Delivery strategy:
  send_to_device(user_id, device_id, payload)  — per-device E2EE ciphertext
  send_to_user(user_id, payload)               — broadcast (typing, home_changed, etc.)
"""
from fastapi import WebSocket


class ConnectionManager:
    def __init__(self):
        # Keyed by user_id — for broadcast and is_online
        self.active: dict[str, set[WebSocket]] = {}
        # Keyed by device_id — for per-device E2EE delivery
        self.active_by_device: dict[str, WebSocket] = {}
        # Reverse map ws → device_id (for disconnect cleanup)
        self._device_of: dict[WebSocket, str] = {}

    async def connect(self, user_id: str, device_id: str, ws: WebSocket) -> None:
        await ws.accept()
        self.active.setdefault(user_id, set()).add(ws)
        # If the same device reconnects, replace the old socket
        old_ws = self.active_by_device.get(device_id)
        if old_ws and old_ws is not ws:
            self.active.get(user_id, set()).discard(old_ws)
            self._device_of.pop(old_ws, None)
        self.active_by_device[device_id] = ws
        self._device_of[ws] = device_id

    def disconnect(self, user_id: str, ws: WebSocket) -> None:
        conns = self.active.get(user_id)
        if conns and ws in conns:
            conns.discard(ws)
            if not conns:
                del self.active[user_id]
        device_id = self._device_of.pop(ws, None)
        if device_id and self.active_by_device.get(device_id) is ws:
            del self.active_by_device[device_id]

    def is_online(self, user_id: str) -> bool:
        return bool(self.active.get(user_id))

    def is_device_online(self, device_id: str) -> bool:
        return device_id in self.active_by_device

    def connection_count(self) -> int:
        """Total number of active WebSocket connections across all users."""
        return sum(len(conns) for conns in self.active.values())

    async def send_to_device(self, device_id: str, payload: dict) -> bool:
        """
        Deliver payload to a specific device. Returns True if delivered.
        Used for per-device E2EE ciphertext (Task #57).
        """
        ws = self.active_by_device.get(device_id)
        if not ws:
            return False
        try:
            await ws.send_json(payload)
            return True
        except Exception:
            # Socket is dead — clean up
            self._device_of.pop(ws, None)
            del self.active_by_device[device_id]
            return False

    async def send_to_user(self, user_id: str, payload: dict) -> bool:
        """Broadcast to ALL connected devices of user_id. Returns True if delivered to ≥1."""
        conns = self.active.get(user_id)
        if not conns:
            return False
        dead = []
        for ws in list(conns):
            try:
                await ws.send_json(payload)
            except Exception:
                dead.append(ws)
        for ws in dead:
            conns.discard(ws)
            device_id = self._device_of.pop(ws, None)
            if device_id and self.active_by_device.get(device_id) is ws:
                del self.active_by_device[device_id]
        return len(conns) > 0


manager = ConnectionManager()
