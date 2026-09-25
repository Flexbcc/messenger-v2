"""Bounded, identifier-free delivery timing diagnostics.

Only aggregate stage durations are retained. Message, user, conversation and
route identifiers never enter this module.
"""

from __future__ import annotations

import math
from collections import deque


MAX_SAMPLES_PER_STAGE = 512
ALLOWED_STAGES = frozenset(
    {
        "sender_db_commit",
        "sender_fanout",
        "sender_total",
        "target_key_lookup",
        "direct_home_request",
        "receiver_envelope_verify",
        "receiver_identity_verify",
        "receiver_db_commit",
        "receiver_ws_delivery",
        "receiver_total",
    }
)
_samples = {stage: deque(maxlen=MAX_SAMPLES_PER_STAGE) for stage in ALLOWED_STAGES}


def record_delivery_stage(stage: str, duration_ms: float) -> None:
    if stage not in ALLOWED_STAGES:
        raise ValueError("unknown delivery timing stage")
    if not isinstance(duration_ms, (int, float)) or not math.isfinite(duration_ms):
        return
    _samples[stage].append(max(0.0, float(duration_ms)))


def _percentile(values: list[float], ratio: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    index = min(len(ordered) - 1, max(0, math.ceil(len(ordered) * ratio) - 1))
    return round(ordered[index], 3)


def delivery_timing_snapshot() -> dict[str, dict[str, float | int | None]]:
    result = {}
    for stage in sorted(ALLOWED_STAGES):
        values = list(_samples[stage])
        if not values:
            continue
        result[stage] = {
            "samples": len(values),
            "avg_ms": round(sum(values) / len(values), 3),
            "p50_ms": _percentile(values, 0.50),
            "p95_ms": _percentile(values, 0.95),
            "p99_ms": _percentile(values, 0.99),
            "max_ms": round(max(values), 3),
        }
    return result
