from functools import lru_cache

from fastapi import HTTPException

from app.config import NETWORK_VIEW_STATE_PATH
from shared.security.network_view import NetworkViewGuard


@lru_cache
def get_network_view_guard() -> NetworkViewGuard:
    return NetworkViewGuard(NETWORK_VIEW_STATE_PATH)


def require_governance_available() -> None:
    decision = get_network_view_guard().decision()
    if not decision.governance_allowed:
        raise HTTPException(
            status_code=503,
            detail=f"control plane is frozen: {decision.frozen_reason}",
        )
