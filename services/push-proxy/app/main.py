"""
Push Proxy — privacy-first push notification gateway.

Принципы:
- Payload минимален: {"type": "incoming_call"} без контента.
  Реальные данные (SDP, caller) доставляются через WS/federation после wakeup.
- Tokens хранятся в SQLite, привязаны к (user_id, device_id).
- Home-node вызывает /notify при call_offer для offline/background получателя.
- Поддерживает FCM (Android) и APNs (iOS) — оба опциональны через env vars.
- Без FCM/APNs отправляет WebSocket push если клиент онлайн (fallback).

Env vars:
  FCM_SERVER_KEY      — Firebase Cloud Messaging server key (Android)
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
import os

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.db import init_db
from app.routers import notify, tokens, health

logging.basicConfig(level=logging.INFO)
_log = logging.getLogger(__name__)

app = FastAPI(title="Push Proxy", version="0.1.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(health.router)
app.include_router(tokens.router)
app.include_router(notify.router)


@app.on_event("startup")
async def on_startup():
    await init_db()
    _log.info("Push proxy started. FCM=%s APNs=%s",
              bool(os.environ.get("FCM_SERVER_KEY")),
              bool(os.environ.get("APNS_KEY_ID")))
