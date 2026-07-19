import os
import secrets as secrets_mod
from pathlib import Path

import httpx
from fastapi import FastAPI, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, Response
from fastapi.staticfiles import StaticFiles

from app.config_io import (
    ENV_PATH,
    PROJECT_ROOT,
    STORAGE_CONFIG_PATH,
    parse_env_file,
    read_env_config,
    read_full_config,
    write_full_config,
    write_storage_config,
    write_env_config,
)
from app.schemas import FullAdminConfig, NodeEnvConfig, StorageConfigFile
from app.secrets import merge_node_secrets, merge_storage_secrets, read_full_config_for_api

ADMIN_PANEL_SECRET = os.environ.get("ADMIN_PANEL_SECRET", "")

ADMIN_STATIC = Path(os.environ.get("ADMIN_STATIC", PROJECT_ROOT / "admin"))

app = FastAPI(title="Messenger Admin", version="0.1.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.middleware("http")
async def admin_panel_guard(request: Request, call_next):
    if ADMIN_PANEL_SECRET and request.url.path.startswith("/api/"):
        write_op = request.method in ("PUT", "POST", "DELETE") and not request.url.path.startswith(
            "/api/enrollment/"
        )
        if write_op:
            token = request.headers.get("X-Admin-Panel-Secret", "")
            if not secrets_mod.compare_digest(token, ADMIN_PANEL_SECRET):
                return Response(
                    content='{"detail":"Admin panel authentication required"}',
                    status_code=401,
                    media_type="application/json",
                )
    return await call_next(request)


@app.get("/health")
def health():
    return {
        "status": "ok",
        "node_role": "admin",
        "load": {
            "env_exists": ENV_PATH.exists(),
            "storage_config_exists": STORAGE_CONFIG_PATH.exists(),
            "panel_auth": bool(ADMIN_PANEL_SECRET),
        },
    }


@app.get("/api/config")
def get_config():
    env_map = parse_env_file()
    full = read_full_config()
    return read_full_config_for_api(env_map, full)


@app.put("/api/config")
def put_config(config: FullAdminConfig):
    env_map = parse_env_file()
    existing = read_full_config()
    merged_node = merge_node_secrets(config.node, env_map)
    merged_storage = merge_storage_secrets(config.storage, existing.storage)
    write_full_config(FullAdminConfig(node=merged_node, storage=merged_storage))
    return {"status": "saved", "message": "Конфиг сохранён. Перезапустите ноды: docker compose up -d --build"}


@app.put("/api/config/node")
def put_node_config(node: NodeEnvConfig):
    env_map = parse_env_file()
    merged = merge_node_secrets(node, env_map)
    write_env_config(merged)
    return {"status": "saved", "path": str(ENV_PATH)}


@app.put("/api/config/storage")
def put_storage_config(storage: StorageConfigFile):
    existing = read_full_config()
    merged = merge_storage_secrets(storage, existing.storage)
    write_storage_config(merged)
    return {"status": "saved", "path": str(STORAGE_CONFIG_PATH)}


@app.get("/api/monitor/registry/nodes")
async def monitor_registry_nodes():
    """Registry list for Node Monitor — server-side proxy to discovery."""
    cfg = read_env_config()
    url = f"{cfg.discovery_node_url.rstrip('/')}/registry/nodes"
    try:
        async with httpx.AsyncClient(timeout=15.0) as client:
            resp = await client.get(url, params={"include_untrusted": "true"})
            resp.raise_for_status()
            return resp.json()
    except httpx.HTTPStatusError as e:
        raise HTTPException(status_code=e.response.status_code, detail=e.response.text) from e
    except httpx.RequestError as e:
        raise HTTPException(status_code=502, detail=f"Cannot reach discovery: {e}") from e


@app.get("/api/config/paths")
def config_paths():
    return {
        "env_file": str(ENV_PATH),
        "storage_config": str(STORAGE_CONFIG_PATH),
        "project_root": str(PROJECT_ROOT),
    }


@app.post("/api/storage/reload-media")
async def reload_media_config():
    """Ask media-node to reload storage.json (best-effort)."""
    import httpx

    media_url = os.environ.get("MEDIA_NODE_URL", "http://media-node:8004")
    try:
        async with httpx.AsyncClient(timeout=5.0) as client:
            resp = await client.post(f"{media_url.rstrip('/')}/admin/reload-config")
            resp.raise_for_status()
            return resp.json()
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"media-node reload failed: {e}")


@app.post("/api/storage/backup")
async def trigger_backup():
    import httpx

    media_url = os.environ.get("MEDIA_NODE_URL", "http://media-node:8004")
    try:
        async with httpx.AsyncClient(timeout=120.0) as client:
            resp = await client.post(f"{media_url.rstrip('/')}/admin/backup")
            resp.raise_for_status()
            return resp.json()
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"backup failed: {e}")


@app.get("/")
def index_page():
    return FileResponse(ADMIN_STATIC / "index.html")


@app.get("/setup")
def setup_page():
    return FileResponse(ADMIN_STATIC / "setup.html")


@app.get("/storage")
def storage_page():
    return FileResponse(ADMIN_STATIC / "storage.html")


@app.get("/enrollment")
def enrollment_page():
    return FileResponse(ADMIN_STATIC / "enrollment.html")


@app.api_route("/api/enrollment/proxy", methods=["GET", "POST"])
async def enrollment_proxy(
    request: Request,
    discovery_url: str,
    path: str,
):
    """Forward Control Plane admin calls to discovery-node (browser CORS workaround)."""
    secret = request.headers.get("X-Discovery-Admin-Secret", "")
    if not secret:
        raise HTTPException(status_code=400, detail="X-Discovery-Admin-Secret required")
    if not path.startswith("/admin/"):
        raise HTTPException(status_code=400, detail="path must start with /admin/")
    url = f"{discovery_url.rstrip('/')}{path}"
    headers = {"X-Discovery-Admin-Secret": secret}
    try:
        async with httpx.AsyncClient(timeout=15.0) as client:
            resp = await client.request(
                request.method,
                url,
                headers=headers,
                content=await request.body(),
            )
    except httpx.RequestError as e:
        raise HTTPException(
            status_code=502,
            detail=f"Cannot reach discovery at {discovery_url!r}: {e}. "
            "Use http://discovery-node:8003 (Docker) or http://<main-ip>:8003 — not localhost.",
        ) from e
    return Response(
        content=resp.content,
        status_code=resp.status_code,
        media_type=resp.headers.get("content-type", "application/json"),
    )


if ADMIN_STATIC.is_dir():
    app.mount("/static", StaticFiles(directory=str(ADMIN_STATIC)), name="static")
