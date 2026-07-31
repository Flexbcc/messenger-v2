"""Security counters for /health endpoints."""
from shared.security.config import INTERNAL_SECURITY_MODE, FEDERATION_ENVELOPE_MODE
from shared.security.metrics import metrics


def security_health_snapshot() -> dict:
    m = metrics()
    return {
        "mode": INTERNAL_SECURITY_MODE,
        "envelope_mode": FEDERATION_ENVELOPE_MODE,
        "invalid_signature": m.invalid_signature,
        "replay_rejected": m.replay_rejected,
        "untrusted_node": m.untrusted_node,
        "capability_denied": m.capability_denied,
        "timestamp_rejected": m.timestamp_rejected,
        "rate_limit_hits": m.rate_limit_hits,
    }
