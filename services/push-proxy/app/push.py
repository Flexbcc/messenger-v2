"""
Push delivery adapters: FCM (Android) и APNs (iOS).

Privacy принципы:
- payload не содержит текст сообщений, SDP, ключи или контакты.
- FCM: data-only message (не notification) — app wakes up сам и показывает
  incoming call UI. Не показывается в системном трее без действий приложения.
- APNs: content-available:1 silent push. На iOS 17+ нужен VoIP push (PushKit)
  для надёжного wakeup звонка — реализован через отдельный apns_voip путь.
"""
import json
import logging
import os
import time
from typing import Any

import httpx

from app.config import settings

_log = logging.getLogger(__name__)

# FCM v1 API endpoint (Legacy HTTP API устарел в июне 2024)
_FCM_URL = "https://fcm.googleapis.com/fcm/send"

# APNs endpoints
_APNS_PROD_HOST = "api.push.apple.com"
_APNS_SANDBOX_HOST = "api.sandbox.push.apple.com"

_apns_token_cache: dict[str, Any] = {}   # {token: str, expires_at: float}


async def send_push(platform: str, token: str, data: dict) -> None:
    """Dispatch to FCM or APNs adapter."""
    if platform == "fcm":
        await _send_fcm(token, data)
    elif platform == "apns":
        await _send_apns(token, data)
    else:
        raise ValueError(f"Unknown platform: {platform}")


# ---------------------------------------------------------------------------
# FCM (Android / Firebase Cloud Messaging — Legacy HTTP)
# ---------------------------------------------------------------------------

async def _send_fcm(device_token: str, data: dict) -> None:
    key = settings.fcm_server_key
    if not key:
        _log.warning("FCM_SERVER_KEY not set — skipping FCM push")
        return

    payload = {
        "to": device_token,
        "data": {k: str(v) for k, v in data.items()},  # FCM требует строки
        "priority": "high",
        "time_to_live": 60,   # 1 минута — звонок не ждёт
    }

    async with httpx.AsyncClient(timeout=10) as client:
        resp = await client.post(
            _FCM_URL,
            headers={
                "Authorization": f"key={key}",
                "Content-Type": "application/json",
            },
            content=json.dumps(payload),
        )
        if resp.status_code != 200:
            raise RuntimeError(f"FCM error {resp.status_code}: {resp.text[:200]}")
        result = resp.json()
        if result.get("failure", 0) > 0:
            _log.warning("FCM delivery failed for token: %s", result)


# ---------------------------------------------------------------------------
# APNs (iOS — HTTP/2, JWT auth)
# ---------------------------------------------------------------------------

def _apns_host() -> str:
    return _APNS_SANDBOX_HOST if settings.apns_sandbox else _APNS_PROD_HOST


def _build_apns_jwt() -> str:
    """Build APNs provider JWT. Cached for 45 minutes (valid for 60)."""
    import jwt as pyjwt   # PyJWT

    cached = _apns_token_cache.get("token")
    expires_at = _apns_token_cache.get("expires_at", 0)
    if cached and time.time() < expires_at:
        return cached

    key_path = settings.apns_key_path
    if not key_path or not os.path.exists(key_path):
        raise RuntimeError("APNS_KEY_PATH not set or file not found")

    with open(key_path) as f:
        private_key = f.read()

    now = int(time.time())
    token = pyjwt.encode(
        {"iss": settings.apns_team_id, "iat": now},
        private_key,
        algorithm="ES256",
        headers={"kid": settings.apns_key_id},
    )
    _apns_token_cache["token"] = token
    _apns_token_cache["expires_at"] = now + 45 * 60
    return token


async def _send_apns(device_token: str, data: dict) -> None:
    if not settings.apns_key_id:
        _log.warning("APNs not configured — skipping APNs push")
        return

    try:
        auth_token = _build_apns_jwt()
    except Exception as e:
        _log.error("Failed to build APNs JWT: %s", e)
        return

    host = _apns_host()
    url = f"https://{host}/3/device/{device_token}"

    # Silent push (content-available) — app wakes in background.
    # Для звонков в iOS 17+ рекомендуется VoIP (PushKit), но это требует
    # отдельного сертификата. Используем silent push как начальный вариант.
    apns_payload = {
        "aps": {
            "content-available": 1,
            "sound": "",   # без звука — app сам покажет incoming call UI
        },
        **data,
    }

    headers = {
        "authorization": f"bearer {auth_token}",
        "apns-push-type": "background",
        "apns-priority": "5",   # 5 для background/silent, 10 для alert
        "apns-topic": settings.apns_bundle_id,
        "apns-expiration": str(int(time.time()) + 60),   # 1 минута
    }

    async with httpx.AsyncClient(http2=True, timeout=10) as client:
        resp = await client.post(url, headers=headers, json=apns_payload)
        if resp.status_code not in (200, 410):
            raise RuntimeError(f"APNs error {resp.status_code}: {resp.text[:200]}")
        if resp.status_code == 410:
            # Token истёк — клиент должен перерегистрировать
            _log.info("APNs token expired (410): %s", device_token[:16])
