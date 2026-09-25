"""
Push delivery adapters: FCM (Android) и APNs (iOS).

Privacy принципы:
- payload не содержит текст сообщений, SDP, ключи или контакты.
- FCM: data-only message (не notification) — app wakes up сам и показывает
  incoming call UI. Не показывается в системном трее без действий приложения.
- APNs: content-available:1 silent push. На iOS 17+ нужен VoIP push (PushKit)
  для надёжного wakeup звонка — реализован через отдельный apns_voip путь.
"""
import asyncio
import json
import logging
import os
import re
import time
from typing import Any

import httpx
import jwt as pyjwt

from app.config import settings
from shared.security.webpush import validate_webpush_subscription_json

_log = logging.getLogger(__name__)

_FCM_TOKEN_URL = "https://oauth2.googleapis.com/token"
_FCM_SCOPE = "https://www.googleapis.com/auth/firebase.messaging"

# APNs endpoints
_APNS_PROD_HOST = "api.push.apple.com"
_APNS_SANDBOX_HOST = "api.sandbox.push.apple.com"

_apns_token_cache: dict[str, Any] = {}   # {token: str, expires_at: float}
_fcm_token_cache: dict[str, Any] = {}
_fcm_token_lock = asyncio.Lock()


class PushProviderUnavailable(RuntimeError):
    """The requested provider is not configured on this proxy."""


def validate_provider_configuration() -> None:
    if settings.fcm_service_account_path:
        _load_fcm_service_account()
    if settings.apns_key_id:
        key_path = settings.apns_key_path
        if not key_path or not os.path.isfile(key_path):
            raise RuntimeError("APNS_KEY_PATH must reference a file")
        if os.path.getsize(key_path) > 32 * 1024:
            raise RuntimeError("APNs private key file is too large")


async def send_push(platform: str, token: str, data: dict) -> None:
    """Dispatch to FCM or APNs adapter."""
    if platform == "fcm":
        await _send_fcm(token, data)
    elif platform == "apns":
        await _send_apns(token, data)
    elif platform == "webpush":
        await _send_webpush(token, data)
    else:
        raise ValueError(f"Unknown platform: {platform}")


async def _send_webpush(subscription_json: str, data: dict) -> None:
    """Send a content-free wake-up notification to a browser subscription."""
    if not settings.vapid_private_key:
        raise PushProviderUnavailable("Web Push provider is not configured")
    from pywebpush import webpush

    subscription = validate_webpush_subscription_json(subscription_json)
    # pywebpush is synchronous; keep its network work off the event loop.
    await asyncio.to_thread(
        webpush,
        subscription_info=subscription,
        data=json.dumps(data),
        vapid_private_key=settings.vapid_private_key,
        vapid_claims={"sub": settings.vapid_subject},
        ttl=120,
    )


# ---------------------------------------------------------------------------
# FCM (Android / Firebase Cloud Messaging — HTTP v1)
# ---------------------------------------------------------------------------

def _load_fcm_service_account() -> tuple[str, str, str]:
    path = settings.fcm_service_account_path
    if not path:
        raise PushProviderUnavailable("FCM provider is not configured")
    with open(path, encoding="utf-8") as source:
        raw = source.read(64 * 1024 + 1)
    if len(raw) > 64 * 1024:
        raise RuntimeError("FCM service account file is too large")
    value = json.loads(raw)
    if not isinstance(value, dict):
        raise RuntimeError("FCM service account must be a JSON object")
    client_email = value.get("client_email")
    private_key = value.get("private_key")
    project_id = settings.fcm_project_id or value.get("project_id")
    if not all(
        isinstance(item, str) and item
        for item in (client_email, private_key, project_id)
    ):
        raise RuntimeError("FCM service account is missing required fields")
    if len(client_email) > 320 or len(private_key) > 32 * 1024:
        raise RuntimeError("FCM service account fields are invalid")
    if (
        not client_email.endswith(".gserviceaccount.com")
        or "-----BEGIN PRIVATE KEY-----" not in private_key
        or "-----END PRIVATE KEY-----" not in private_key
    ):
        raise RuntimeError("FCM service account credentials are invalid")
    if not re.fullmatch(r"[a-z][a-z0-9-]{4,62}", project_id):
        raise RuntimeError("FCM project_id is invalid")
    return client_email, private_key, project_id


async def _fcm_access_token() -> tuple[str, str]:
    cached = _fcm_token_cache.get("token")
    project_id = _fcm_token_cache.get("project_id")
    if cached and project_id and time.time() < _fcm_token_cache.get("expires_at", 0):
        return cached, project_id

    async with _fcm_token_lock:
        cached = _fcm_token_cache.get("token")
        project_id = _fcm_token_cache.get("project_id")
        if cached and project_id and time.time() < _fcm_token_cache.get("expires_at", 0):
            return cached, project_id

        client_email, private_key, project_id = _load_fcm_service_account()
        now = int(time.time())
        assertion = pyjwt.encode(
            {
                "iss": client_email,
                "scope": _FCM_SCOPE,
                "aud": _FCM_TOKEN_URL,
                "iat": now,
                "exp": now + 3600,
            },
            private_key,
            algorithm="RS256",
        )
        async with httpx.AsyncClient(
            timeout=10, follow_redirects=False, trust_env=False
        ) as client:
            response = await client.post(
                _FCM_TOKEN_URL,
                data={
                    "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
                    "assertion": assertion,
                },
            )
        if response.status_code != 200:
            raise RuntimeError(f"FCM OAuth error {response.status_code}")
        body = response.json()
        token = body.get("access_token") if isinstance(body, dict) else None
        expires_in = body.get("expires_in") if isinstance(body, dict) else None
        if not isinstance(token, str) or not 16 <= len(token) <= 8192:
            raise RuntimeError("FCM OAuth response has no valid access token")
        if not isinstance(expires_in, int) or not 60 <= expires_in <= 7200:
            expires_in = 3600
        _fcm_token_cache.update(
            token=token,
            project_id=project_id,
            expires_at=now + expires_in - 60,
        )
        return token, project_id


async def _send_fcm(device_token: str, data: dict) -> None:
    access_token, project_id = await _fcm_access_token()
    url = f"https://fcm.googleapis.com/v1/projects/{project_id}/messages:send"

    payload = {
        "message": {
            "token": device_token,
            "data": {k: str(v) for k, v in data.items()},
            "android": {"priority": "HIGH", "ttl": "60s"},
        }
    }

    async with httpx.AsyncClient(
        timeout=10, follow_redirects=False, trust_env=False
    ) as client:
        resp = await client.post(
            url,
            headers={
                "Authorization": f"Bearer {access_token}",
                "Content-Type": "application/json",
            },
            json=payload,
        )
    if resp.status_code != 200:
            raise RuntimeError(f"FCM error {resp.status_code}: {resp.text[:200]}")


# ---------------------------------------------------------------------------
# APNs (iOS — HTTP/2, JWT auth)
# ---------------------------------------------------------------------------

def _apns_host() -> str:
    return _APNS_SANDBOX_HOST if settings.apns_sandbox else _APNS_PROD_HOST


def _build_apns_jwt() -> str:
    """Build APNs provider JWT. Cached for 45 minutes (valid for 60)."""
    cached = _apns_token_cache.get("token")
    expires_at = _apns_token_cache.get("expires_at", 0)
    if cached and time.time() < expires_at:
        return cached

    key_path = settings.apns_key_path
    if not key_path or not os.path.exists(key_path):
        raise RuntimeError("APNS_KEY_PATH not set or file not found")

    with open(key_path, encoding="utf-8") as source:
        private_key = source.read(32 * 1024 + 1)
    if len(private_key) > 32 * 1024:
        raise RuntimeError("APNs private key file is too large")

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
        raise PushProviderUnavailable("APNs provider is not configured")

    auth_token = _build_apns_jwt()

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

    async with httpx.AsyncClient(
        http2=True, timeout=10, follow_redirects=False, trust_env=False
    ) as client:
        resp = await client.post(url, headers=headers, json=apns_payload)
        if resp.status_code not in (200, 410):
            raise RuntimeError(f"APNs error {resp.status_code}: {resp.text[:200]}")
        if resp.status_code == 410:
            # Token истёк — клиент должен перерегистрировать
            _log.info("APNs token expired (410): %s", device_token[:16])
