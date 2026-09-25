from fastapi import APIRouter

from app.config import settings

router = APIRouter(tags=["health"])


@router.get("/health")
async def health():
    return {
        "status": "ok",
        "service": "push-proxy",
        "fcm": bool(settings.fcm_service_account_path),
        "apns": bool(settings.apns_key_id),
        "webpush": bool(settings.vapid_private_key and settings.vapid_public_key),
    }
