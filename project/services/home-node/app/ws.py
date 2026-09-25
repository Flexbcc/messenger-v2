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
import asyncio
import logging

from fastapi import WebSocket

logger = logging.getLogger(__name__)
MAX_ACTIVE_CONNECTIONS = 10000
MAX_CONNECTIONS_PER_USER = 64
SEND_TIMEOUT_SECONDS = 5.0


class ConnectionManager:
    def __init__(self):
        # Keyed by user_id — for broadcast and is_online
        self.active: dict[str, set[WebSocket]] = {}
        # Keyed by device_id — for per-device E2EE delivery
        self.active_by_device: dict[str, WebSocket] = {}
        # Reverse map ws → device_id (for disconnect cleanup)
        self._device_of: dict[WebSocket, str] = {}

    def _drop_socket(self, ws: WebSocket) -> None:
        device_id = self._device_of.pop(ws, None)
        if device_id and self.active_by_device.get(device_id) is ws:
            self.active_by_device.pop(device_id, None)
        for user_id, connections in list(self.active.items()):
            connections.discard(ws)
            if not connections:
                self.active.pop(user_id, None)

    async def connect(self, user_id: str, device_id: str, ws: WebSocket) -> bool:
        # If the same device reconnects, replace the old socket
        old_ws = self.active_by_device.get(device_id)
        if old_ws and old_ws is not ws:
            try:
                await asyncio.wait_for(
                    old_ws.close(code=4410, reason="superseded"),
                    timeout=SEND_TIMEOUT_SECONDS,
                )
            except Exception:
                pass
            self._drop_socket(old_ws)
        user_connections = self.active.get(user_id, set())
        if self.connection_count() >= MAX_ACTIVE_CONNECTIONS:
            await ws.close(code=4429, reason="connection capacity reached")
            return False
        if len(user_connections) >= MAX_CONNECTIONS_PER_USER:
            await ws.close(code=4429, reason="user connection capacity reached")
            return False
        await ws.accept()
        user_connections = self.active.setdefault(user_id, set())
        user_connections.add(ws)
        self.active_by_device[device_id] = ws
        self._device_of[ws] = device_id
        return True

    def disconnect(self, ws: WebSocket) -> None:
        self._drop_socket(ws)

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
            await asyncio.wait_for(
                ws.send_json(payload), timeout=SEND_TIMEOUT_SECONDS
            )
            return True
        except Exception:
            # Socket is dead — clean up
            self._drop_socket(ws)
            return False

    async def send_to_user(self, user_id: str, payload: dict) -> bool:
        """Broadcast to ALL connected devices of user_id. Returns True if delivered to ≥1."""
        conns = self.active.get(user_id)
        if not conns:
            return False
        dead = []
        for ws in list(conns):
            try:
                await asyncio.wait_for(
                    ws.send_json(payload), timeout=SEND_TIMEOUT_SECONDS
                )
            except Exception:
                dead.append(ws)
        for ws in dead:
            self._drop_socket(ws)
        return bool(self.active.get(user_id))

    async def revoke_device(self, device_id: str) -> None:
        ws = self.active_by_device.get(device_id)
        if not ws:
            return
        try:
            await asyncio.wait_for(
                ws.send_json({"type": "session_revoked"}),
                timeout=SEND_TIMEOUT_SECONDS,
            )
            await asyncio.wait_for(
                ws.close(code=4401), timeout=SEND_TIMEOUT_SECONDS
            )
        except Exception:
            logger.exception(
                "Failed to notify or close revoked device websocket",
                extra={"device_id": device_id},
            )
        self._drop_socket(ws)


manager = ConnectionManager()
