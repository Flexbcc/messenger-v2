import os
from fastapi import APIRouter

router = APIRouter(tags=["health"])


@router.get("/health")
async def health():
    return {
        "status": "ok",
        "service": "push-proxy",
        "fcm": bool(os.environ.get("FCM_SERVER_KEY")),
        "apns": bool(os.environ.get("APNS_KEY_ID")),
    }
