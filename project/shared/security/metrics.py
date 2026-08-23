import time
import threading
from collections import OrderedDict
from dataclasses import dataclass, field


@dataclass
class SecurityMetrics:
    invalid_signature: int = 0
    replay_rejected: int = 0
    untrusted_node: int = 0
    capability_denied: int = 0
    timestamp_rejected: int = 0
    rate_limit_hits: int = 0
    admission_rejected: int = 0


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
    def __init__(
        self,
        rate: float = 50.0,
        capacity: float = 100.0,
        *,
        max_buckets: int = 10_000,
        idle_ttl_seconds: float = 600.0,
    ):
        if rate <= 0 or capacity <= 0:
            raise ValueError("rate and capacity must be positive")
        if max_buckets < 1 or idle_ttl_seconds <= 0:
            raise ValueError("rate limiter bounds must be positive")
        self._rate = rate
        self._capacity = capacity
        self._max_buckets = max_buckets
        self._idle_ttl_seconds = idle_ttl_seconds
        self._buckets: OrderedDict[str, TokenBucket] = OrderedDict()
        self._lock = threading.Lock()

    def allow(self, key: str) -> bool:
        if not isinstance(key, str) or not 1 <= len(key) <= 256:
            return False
        now = time.monotonic()
        with self._lock:
            bucket = self._buckets.get(key)
            if bucket is None:
                while self._buckets:
                    oldest_key, oldest = next(iter(self._buckets.items()))
                    if now - oldest.updated_at <= self._idle_ttl_seconds:
                        break
                    self._buckets.pop(oldest_key, None)
                if len(self._buckets) >= self._max_buckets:
                    return False
                bucket = TokenBucket(rate=self._rate, capacity=self._capacity)
                self._buckets[key] = bucket
            else:
                self._buckets.move_to_end(key)
            return bucket.allow()

    @property
    def bucket_count(self) -> int:
        with self._lock:
            return len(self._buckets)
