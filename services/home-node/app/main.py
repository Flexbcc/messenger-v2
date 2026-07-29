import asyncio
import logging
import os
from datetime import datetime, timedelta
from pathlib import Path

from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, HTMLResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles

from app.config import settings
from app.db import init_db

_log = logging.getLogger(__name__)
# Устройства без активности дольше этого срока считаются мёртвыми и удаляются.
_DEVICE_STALE_DAYS = int(os.environ.get("DEVICE_STALE_DAYS", "90"))
_DEVICE_CLEANUP_INTERVAL = int(os.environ.get("DEVICE_CLEANUP_INTERVAL_SECONDS", "86400"))  # раз в сутки


async def _device_cleanup_loop() -> None:
    """Удаляет Device-записи без активности > DEVICE_STALE_DAYS дней."""
    from sqlalchemy import delete as sa_delete
    from app.db import async_session
    from app.models import Device
    while True:
        await asyncio.sleep(_DEVICE_CLEANUP_INTERVAL)
        cutoff = datetime.utcnow() - timedelta(days=_DEVICE_STALE_DAYS)
        try:
            async with async_session() as session:
                result = await session.execute(
                    sa_delete(Device).where(Device.last_active < cutoff).returning(Device.id)
                )
                deleted = len(result.fetchall())
                await session.commit()
            if deleted:
                _log.info("Device cleanup: удалено %d устаревших устройств (неактивны > %d дней)", deleted, _DEVICE_STALE_DAYS)
        except Exception as exc:
            _log.warning("Device cleanup error (non-fatal): %s", exc)
_REVOKED_CLEANUP_INTERVAL = int(os.environ.get("REVOKED_TOKENS_CLEANUP_INTERVAL_SECONDS", "3600"))  # раз в час


async def _revoked_tokens_cleanup_loop() -> None:
    """Удаляет истёкшие записи из revoked_tokens раз в час."""
    from app.db import async_session
    from app.security import cleanup_revoked_tokens
    while True:
        await asyncio.sleep(_REVOKED_CLEANUP_INTERVAL)
        try:
            async with async_session() as session:
                deleted = await cleanup_revoked_tokens(session)
            if deleted:
                _log.info("Revoked tokens cleanup: удалено %d истёкших записей", deleted)
        except Exception as exc:
            _log.warning("Revoked tokens cleanup error (non-fatal): %s", exc)


from app.node_registration import start_node_registration
from app.ops_proxy import proxy_to_ops_admin
from app.outbox import start_outbox_worker
from shared.security.nonce_cleanup import start_nonce_cleanup
from app.routers import auth, conversations, devices, internal, media_proxy, messages, monitor, security_signals, storage, users, ws
from app.ws import manager
from shared.security.health import security_health_snapshot
from app.federation import get_federation_counters

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
    start_outbox_worker()
    from app.fed_security import get_federation_security
    start_nonce_cleanup(get_federation_security().nonce_store)
    asyncio.create_task(_device_cleanup_loop())
    asyncio.create_task(_revoked_tokens_cleanup_loop())
    # Исчезающие сообщения (Task #70): sweep expired messages
    from app.disappearing import delete_expired_messages
    from app.db import async_session
    asyncio.create_task(delete_expired_messages(async_session))


@app.get("/health")
def health():
    from app.fed_security import get_federation_security
    fs = get_federation_security()
    resp: dict = {
        "status": "ok",
        "node_role": "home",
        "node_id": settings.node_id,
        "load": {
            "online_users": len(manager.active),
            "active_ws_connections": sum(len(conns) for conns in manager.active.values()),
            "federation": get_federation_counters(),
        },
        "security": security_health_snapshot(),
    }
    # Sealed sender (Task #68): публикуем X25519 public key для шифрования sender_user_id
    curve_pk = fs.curve_public_key
    if curve_pk:
        resp["curve_public_key"] = curve_pk
    return resp


app.include_router(auth.router)
app.include_router(users.router)
app.include_router(devices.router)
app.include_router(conversations.router)
app.include_router(messages.router)
app.include_router(security_signals.router)
app.include_router(internal.router)
app.include_router(media_proxy.router)
app.include_router(monitor.router)
app.include_router(storage.router)
app.include_router(storage.me_router)
app.include_router(ws.router)

if PANEL_DIR.is_dir():
    @app.get("/panel")
    @app.get("/panel/")
    def owner_panel():
        return FileResponse(PANEL_DIR / "index.html")

    app.mount("/panel/assets", StaticFiles(directory=str(PANEL_DIR)), name="owner-panel")


@app.get("/", response_class=HTMLResponse)
def node_status_page():
    """
    Страница состояния ноды.

    Home-node — это API для мессенджера, а не сайт: к нему подключается
    приложение, а браузером смотреть тут нечего. Раньше на корне отдавался
    голый {"detail":"Not Found"}, из-за чего живая нода выглядела мёртвой.

    Эта страница отвечает на три вопроса: что за нода, работает ли она
    и куда подключать клиент.
    """
    from app.fed_security import get_federation_security

    node_id = settings.node_id
    public_url = os.environ.get("HOME_NODE_PUBLIC_URL", "не задан")
    cluster = os.environ.get("CLUSTER_ID", "default")
    discovery = os.environ.get("DISCOVERY_NODE_URL", "не задан")
    online = len(manager.active)
    ws_conns = sum(len(c) for c in manager.active.values())

    return f"""<!DOCTYPE html>
<html lang="ru"><head><meta charset="utf-8">
<title>Нода {node_id}</title>
<style>
  :root {{ color-scheme: dark; }}
  body {{ margin:0; min-height:100vh; display:flex; align-items:center; justify-content:center;
         background:#0b1220; color:#e2e8f0;
         font:15px/1.6 -apple-system,BlinkMacSystemFont,"Segoe UI",system-ui,sans-serif; }}
  .card {{ width:min(560px,92vw); padding:32px; background:#111c2e;
           border:1px solid #1e293b; border-radius:16px; }}
  h1 {{ margin:0 0 4px; font-size:22px; display:flex; align-items:center; gap:10px; }}
  .dot {{ width:10px; height:10px; border-radius:50%; background:#22c55e; flex:none; }}
  .role {{ color:#94a3b8; font-size:13px; margin:0 0 24px; }}
  dl {{ display:grid; grid-template-columns:auto 1fr; gap:8px 20px; margin:0 0 24px; font-size:13px; }}
  dt {{ color:#94a3b8; }}
  dd {{ margin:0; font-family:ui-monospace,SFMono-Regular,Menlo,monospace; word-break:break-all; }}
  .note {{ padding:14px 16px; background:#0d1729; border:1px solid #1e293b;
           border-radius:10px; font-size:13px; color:#cbd5e1; }}
  .note b {{ color:#e2e8f0; }}
  code {{ background:#0b1220; padding:2px 6px; border-radius:4px; font-size:12px; }}
  a {{ color:#60a5fa; }}
</style></head>
<body><div class="card">
  <h1><span class="dot"></span>{node_id}</h1>
  <p class="role">Home-нода · работает</p>

  <dl>
    <dt>Площадка</dt><dd>{cluster}</dd>
    <dt>Адрес для клиентов</dt><dd>{public_url}</dd>
    <dt>Discovery</dt><dd>{discovery}</dd>
    <dt>Пользователей онлайн</dt><dd>{online}</dd>
    <dt>WS-соединений</dt><dd>{ws_conns}</dd>
  </dl>

  <div class="note">
    <b>Это не веб-интерфейс.</b> Нода отдаёт API для приложения-мессенджера —
    смотреть здесь браузером нечего. Чтобы подключиться, укажите адрес
    <code>{public_url}</code> в клиенте.
    <br><br>
    Состояние в машинном виде: <a href="/health">/health</a>
  </div>
</div></body></html>"""


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
