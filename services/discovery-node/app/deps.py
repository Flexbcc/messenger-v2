"""Admin API authentication (ADR-0009, step 3)."""
import secrets

from fastapi import Header, HTTPException

from app.config import DISCOVERY_ADMIN_SECRET


def require_admin(x_discovery_admin_secret: str = Header(..., alias="X-Discovery-Admin-Secret")) -> None:
    if not DISCOVERY_ADMIN_SECRET:
        raise HTTPException(
            status_code=503,
            detail="Admin API disabled — set DISCOVERY_ADMIN_SECRET on discovery-node",
        )
    if not secrets.compare_digest(x_discovery_admin_secret, DISCOVERY_ADMIN_SECRET):
        raise HTTPException(status_code=401, detail="Invalid admin secret")
