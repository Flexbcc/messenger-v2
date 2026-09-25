"""Opaque security event relay — spec/0404_DURESS_POLICY.md phase 3."""
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

from app.deps import get_current_device
from app.rate_limit import allow
from app.ws import manager

router = APIRouter(tags=["security"])

_RELAY_LIMIT_PER_HOUR = 60


class SecuritySignalIn(BaseModel):
    event: int = Field(..., ge=1, le=99)
    targets: list[str] = Field(default_factory=list, max_length=32)


@router.post("/security-signals")
async def post_security_signal(
    body: SecuritySignalIn,
    auth: tuple[str, str] = Depends(get_current_device),
):
    sender_user_id, device_id = auth
    if not allow(f"security_signal:{device_id}", max_events=_RELAY_LIMIT_PER_HOUR):
        raise HTTPException(status_code=429, detail="security signal rate limit exceeded")

    delivered = 0
    for target_id in body.targets:
        if target_id == sender_user_id:
            continue
        ok = await manager.send_to_user(
            target_id,
            {
                "type": "security_signal",
                "event": body.event,
                "from_user_id": sender_user_id,
            },
        )
        if ok:
            delivered += 1
    return {"ok": True, "delivered": delivered}
