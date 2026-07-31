from fastapi import Depends, Header, HTTPException, Request

from app.config import settings
from shared.security.config import INTERNAL_SECURITY_MODE
from shared.security.jwt_auth import extract_bearer_token, verify_jwt_token
from shared.security.metrics import RateLimiter, metrics

_turn_rate_limiter = RateLimiter(rate=10.0, capacity=20.0)


def _mode_legacy() -> bool:
    return INTERNAL_SECURITY_MODE in ("legacy", "off", "")


async def require_turn_caller(
    request: Request,
    authorization: str | None = Header(default=None),
) -> dict:
    """In signed mode require JWT; legacy allows anonymous local dev."""
    if _mode_legacy():
        return {"sub": "legacy", "device_id": "legacy"}

    token = extract_bearer_token(authorization)
    if not token:
        raise HTTPException(status_code=401, detail="Bearer token required")

    payload = verify_jwt_token(token, settings.jwt_secret)
    if not payload or not payload.get("sub") or not payload.get("device_id"):
        raise HTTPException(status_code=401, detail="Invalid or expired token")

    user_id = str(payload["sub"])
    if not _turn_rate_limiter.allow(user_id):
        metrics().rate_limit_hits += 1
        raise HTTPException(status_code=429, detail="Rate limit exceeded")

    return payload


TurnAuthDep = Depends(require_turn_caller)
