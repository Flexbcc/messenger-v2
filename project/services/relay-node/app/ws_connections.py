"""Bounded in-process accounting for Relay WebSocket connections."""

from __future__ import annotations


class WebSocketConnectionRegistry:
    def __init__(self, *, total_limit: int, per_peer_limit: int):
        if total_limit < 1 or per_peer_limit < 1 or per_peer_limit > total_limit:
            raise ValueError("invalid WebSocket connection limits")
        self._total_limit = total_limit
        self._per_peer_limit = per_peer_limit
        self._active_total = 0
        self._active_by_peer: dict[str, int] = {}

    @property
    def active_total(self) -> int:
        return self._active_total

    @property
    def active_peer_count(self) -> int:
        return len(self._active_by_peer)

    def reserve(self) -> bool:
        if self._active_total >= self._total_limit:
            return False
        self._active_total += 1
        return True

    def bind_peer(self, peer_node_id: str, *, certified_limit: int | None) -> bool:
        if not isinstance(peer_node_id, str) or not peer_node_id:
            return False
        current = self._active_by_peer.get(peer_node_id, 0)
        effective_limit = self._per_peer_limit
        if certified_limit is not None:
            if not isinstance(certified_limit, int) or isinstance(certified_limit, bool):
                return False
            effective_limit = min(effective_limit, certified_limit)
        if effective_limit <= 0 or current >= effective_limit:
            return False
        self._active_by_peer[peer_node_id] = current + 1
        return True

    def release(self, peer_node_id: str | None) -> None:
        self._active_total = max(0, self._active_total - 1)
        if peer_node_id is None:
            return
        remaining = self._active_by_peer.get(peer_node_id, 0) - 1
        if remaining > 0:
            self._active_by_peer[peer_node_id] = remaining
        else:
            self._active_by_peer.pop(peer_node_id, None)
