from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.config import settings
from app.db import init_db
from app.node_registration import start_node_registration
from app.routers import auth, conversations, devices, internal, media_proxy, messages, security_signals, users, ws
from app.ws import manager
from shared.security.health import security_health_snapshot

app = FastAPI(title="Home Node", version="0.1.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # MVP only — tighten before any real deployment
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.on_event("startup")
async def on_startup():
    await init_db()
    start_node_registration()


@app.get("/health")
def health():
    return {
        "status": "ok",
        "node_role": "home",
        "node_id": settings.node_id,
        "load": {
            "online_users": len(manager.active),
            "active_ws_connections": sum(len(conns) for conns in manager.active.values()),
        },
        "security": security_health_snapshot(),
    }


app.include_router(auth.router)
app.include_router(users.router)
app.include_router(devices.router)
app.include_router(conversations.router)
app.include_router(messages.router)
app.include_router(security_signals.router)
app.include_router(internal.router)
app.include_router(media_proxy.router)
app.include_router(ws.router)
