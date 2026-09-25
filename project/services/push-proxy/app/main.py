"""
Push Proxy — privacy-first push notification gateway.

Принципы:
- Payload минимален: {"type": "incoming_call"} без контента.
  Реальные данные (SDP, caller) доставляются через WS/federation после wakeup.
- Tokens хранятся в SQLite, привязаны к (user_id, device_id).
- Home-node вызывает /notify при call_offer для offline/background получателя.
- Поддерживает FCM (Android) и APNs (iOS) — оба опциональны через env vars.

Env vars:
  FCM_SERVICE_ACCOUNT_PATH — Firebase service-account JSON for HTTP v1
  FCM_PROJECT_ID      — optional project override (otherwise from JSON)
  APNS_KEY_ID         — APNs key id (iOS)
  APNS_TEAM_ID        — Apple Team ID (iOS)
  APNS_BUNDLE_ID      — iOS app bundle id (iOS)
  APNS_KEY_PATH       — path to .p8 private key file (iOS)
  APNS_SANDBOX        — "true" для sandbox/development APNs
  PUSH_PROXY_SECRET   — shared secret для аутентификации home-node
  DATABASE_URL        — SQLite path (default: push_tokens.db)
"""
import asyncio
import logging

from fastapi import FastAPI

from app.db import init_db
from app.config import settings, validate_security_configuration
from app.push import validate_provider_configuration
from app.routers import health, internal, notify
from shared.security.body_limit import RequestBodyLimitMiddleware

logging.basicConfig(level=logging.INFO)
_log = logging.getLogger(__name__)

app = FastAPI(title="Push Proxy", version="0.1.0")

app.add_middleware(
    RequestBodyLimitMiddleware,
    path_prefixes=("/notify", "/internal"),
    max_body_bytes=32 * 1024,
    require_federation_headers=False,
)

app.include_router(health.router)
app.include_router(notify.router)
app.include_router(internal.router)


@app.on_event("startup")
async def on_startup():
    validate_security_configuration()
    validate_provider_configuration()
    await init_db()
    _log.info("Push proxy started. FCM=%s APNs=%s WebPush=%s",
              bool(settings.fcm_service_account_path),
              bool(settings.apns_key_id),
              bool(settings.vapid_private_key and settings.vapid_public_key))
