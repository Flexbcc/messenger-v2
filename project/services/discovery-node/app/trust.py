"""Trust lifecycle helpers for Discovery Control Plane (ADR-0009)."""
from datetime import datetime, timedelta, timezone

from app.config import ENROLLMENT_MODE, OFFLINE_THRESHOLD_SECONDS, REACHABILITY_OFFLINE, REACHABILITY_ONLINE


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def reachability_for(last_heartbeat_iso: str) -> str:
    last = datetime.fromisoformat(last_heartbeat_iso)
    age = datetime.now(timezone.utc) - last
    if age < timedelta(seconds=OFFLINE_THRESHOLD_SECONDS):
        return REACHABILITY_ONLINE
    return REACHABILITY_OFFLINE


def enrollment_required() -> bool:
    return ENROLLMENT_MODE in ("strict", "hybrid")


def initial_trust_status_for_register(existing_trust: str | None) -> str:
    """
    Decide trust_status on POST /registry/nodes.

    legacy: always trusted (backward compatible default).
    strict: new nodes → pending; re-register keeps trusted/pending/suspended/compromised.
    hybrid: new node_id → pending; already trusted → trusted.
    """
    if existing_trust in ("suspended", "compromised"):
        return existing_trust
    if existing_trust == "trusted":
        return "trusted"
    if existing_trust == "pending":
        return "pending"
    if ENROLLMENT_MODE == "legacy":
        return "trusted"
    if ENROLLMENT_MODE == "hybrid":
        return "pending"
    # strict — new registration
    return "pending"
