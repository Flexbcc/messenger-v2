from __future__ import annotations

import time


class HomeRouteCache:
    """Bounded in-memory TTL cache for resolved user-to-Home routes."""

    def __init__(self, *, max_entries: int = 10_000) -> None:
        if max_entries < 1:
            raise ValueError("max_entries must be positive")
        self._max_entries = max_entries
        self._entries: dict[str, tuple[str, float]] = {}

    def lookup(self, user_id: str, *, now: float | None = None) -> str | None:
        current = time.monotonic() if now is None else now
        entry = self._entries.get(user_id)
        if entry is None:
            return None
        home_node_url, expires_at = entry
        if current >= expires_at:
            self._entries.pop(user_id, None)
            return None
        return home_node_url

    def store(
        self,
        user_id: str,
        home_node_url: str,
        *,
        ttl_seconds: float,
        now: float | None = None,
    ) -> None:
        if ttl_seconds <= 0:
            return
        current = time.monotonic() if now is None else now
        if user_id not in self._entries and len(self._entries) >= self._max_entries:
            expired = [
                key
                for key, (_, expires_at) in self._entries.items()
                if current >= expires_at
            ]
            for key in expired:
                self._entries.pop(key, None)
            if len(self._entries) >= self._max_entries:
                oldest = min(self._entries, key=lambda key: self._entries[key][1])
                self._entries.pop(oldest, None)
        self._entries[user_id] = (home_node_url, current + ttl_seconds)
