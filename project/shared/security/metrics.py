import time
from collections import defaultdict
from dataclasses import dataclass, field


@dataclass
class SecurityMetrics:
    invalid_signature: int = 0
    replay_rejected: int = 0
    untrusted_node: int = 0
    capability_denied: int = 0
    timestamp_rejected: int = 0
    rate_limit_hits: int = 0


_metrics = SecurityMetrics()


def metrics() -> SecurityMetrics:
    return _metrics


class TokenBucket:
    def __init__(self, rate: float, capacity: float):
        self.rate = rate
        self.capacity = capacity
        self.tokens = capacity
        self.updated_at = time.monotonic()

    def allow(self, cost: float = 1.0) -> bool:
        now = time.monotonic()
        elapsed = now - self.updated_at
        self.updated_at = now
        self.tokens = min(self.capacity, self.tokens + elapsed * self.rate)
        if self.tokens < cost:
            return False
        self.tokens -= cost
        return True


class RateLimiter:
    def __init__(self, rate: float = 50.0, capacity: float = 100.0):
        self._buckets: dict[str, TokenBucket] = defaultdict(
            lambda: TokenBucket(rate=rate, capacity=capacity)
        )

    def allow(self, key: str) -> bool:
        return self._buckets[key].allow()
