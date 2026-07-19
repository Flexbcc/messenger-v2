from pathlib import Path

from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles

from app.config import settings
from app.db import init_db
from app.node_registration import start_node_registration
from app.ops_proxy import proxy_to_ops_admin
from app.routers import auth, conversations, devices, internal, media_proxy, messages, monitor, security_signals, storage, users, ws
from app.ws import manager
from shared.security.health import security_health_snapshot

PANEL_DIR = Path(__file__).parent / "panel"

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
app.include_router(monitor.router)
app.include_router(storage.me_router)
app.include_router(ws.router)

if PANEL_DIR.is_dir():
    @app.get("/panel")
    @app.get("/panel/")
    def owner_panel():
        return FileResponse(PANEL_DIR / "index.html")

    app.mount("/panel/assets", StaticFiles(directory=str(PANEL_DIR)), name="owner-panel")


@app.get("/ops")
async def ops_redirect():
    """Trailing slash required so relative admin assets resolve under /ops/."""
    return RedirectResponse(url="/ops/", status_code=307)


@app.api_route("/ops/", methods=["GET", "POST", "PUT", "DELETE", "PATCH", "HEAD", "OPTIONS"])
async def ops_root(request: Request):
    return await proxy_to_ops_admin(request, "")


@app.api_route("/ops/{path:path}", methods=["GET", "POST", "PUT", "DELETE", "PATCH", "HEAD", "OPTIONS"])
async def ops_path(request: Request, path: str):
    return await proxy_to_ops_admin(request, path)
