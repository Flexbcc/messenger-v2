"""Simple in-memory sliding-window rate limiter."""
from __future__ import annotations

import time
from collections import defaultdict

_buckets: dict[str, list[float]] = defaultdict(list)


def allow(key: str, *, max_events: int, window_sec: int = 3600) -> bool:
    now = time.time()
    kept = [t for t in _buckets[key] if now - t < window_sec]
    if len(kept) >= max_events:
        _buckets[key] = kept
        return False
    kept.append(now)
    _buckets[key] = kept
    return True


def reset(key: str) -> None:
    _buckets.pop(key, None)
