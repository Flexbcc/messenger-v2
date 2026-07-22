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
from app.compose_services import apply_config_restart, service_action, services_status
from app.checks import internal_probe_url, probe_discovery, probe_health, probe_media_admin
from app.registry_metrics import collect_registry_metrics
from pydantic import BaseModel

ADMIN_PANEL_SECRET = os.environ.get("ADMIN_PANEL_SECRET", "")

ADMIN_STATIC = Path(os.environ.get("ADMIN_STATIC", PROJECT_ROOT / "admin"))


class CheckUrlBody(BaseModel):
    url: str = ""
    role: str = ""


class CheckSetupBody(BaseModel):
    discovery_node_url: str = ""
    home_node_public_url: str = ""
    storage_node_url: str = ""
    media_node_public_url: str = ""
    relay_node_public_url: str = ""
    check_media: bool = True
    check_relay: bool = True


class ServiceActionBody(BaseModel):
    services: list[str] | None = None

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
    payload = read_full_config_for_api(env_map, full)
    variant = os.environ.get("ADMIN_VARIANT", "project")
    payload["meta"] = {
        "admin_variant": variant,
        "title": "Главная нода" if variant == "main" else "Project-стек",
    }
    return payload


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


@app.get("/api/monitor/registry/metrics")
async def monitor_registry_metrics():
    """CPU/RAM/load for registered nodes — server-side probes (no browser CORS)."""
    cfg = read_env_config()
    url = f"{cfg.discovery_node_url.rstrip('/')}/registry/nodes"
    try:
        async with httpx.AsyncClient(timeout=15.0) as client:
            resp = await client.get(url, params={"include_untrusted": "true"})
            resp.raise_for_status()
            nodes = resp.json().get("nodes") or []
    except httpx.HTTPStatusError as e:
        raise HTTPException(status_code=e.response.status_code, detail=e.response.text) from e
    except httpx.RequestError as e:
        raise HTTPException(status_code=502, detail=f"Cannot reach discovery: {e}") from e
    metrics = await collect_registry_metrics(nodes)
    return {"nodes": metrics, "count": len(metrics)}


@app.get("/api/monitor/local/snapshot")
async def monitor_local_snapshot():
    """Local Home Node metrics + anonymized connections (no PII)."""
    home_url = os.environ.get("HOME_NODE_URL", "http://home-node:8001").rstrip("/")
    try:
        async with httpx.AsyncClient(timeout=10.0) as client:
            resp = await client.get(f"{home_url}/monitor/snapshot")
            resp.raise_for_status()
            return resp.json()
    except httpx.HTTPStatusError as e:
        raise HTTPException(status_code=e.response.status_code, detail=e.response.text) from e
    except httpx.RequestError as e:
        raise HTTPException(status_code=502, detail=f"Cannot reach home node at {home_url}: {e}") from e


@app.get("/api/config/paths")
def config_paths():
    return {
        "env_file": str(ENV_PATH),
        "storage_config": str(STORAGE_CONFIG_PATH),
        "project_root": str(PROJECT_ROOT),
    }


@app.get("/api/enrollment/hints")
def enrollment_hints():
    """Non-secret enrollment setup hints for Operator Admin UI."""
    env = parse_env_file()
    cfg = read_env_config()
    mode = env.get("ENROLLMENT_MODE", "legacy").lower()
    secret_set = bool(env.get("DISCOVERY_ADMIN_SECRET", "").strip())
    return {
        "discovery_node_url": cfg.discovery_node_url,
        "enrollment_mode": mode,
        "admin_secret_configured": secret_set,
        "admin_api_enabled": secret_set,
        "legacy_mode": mode == "legacy",
        "env_file": str(ENV_PATH),
    }


@app.post("/api/check/health")
async def check_node_health(body: CheckUrlBody):
    probe = internal_probe_url(body.role, body.url) if body.role else body.url.strip()
    if not probe:
        raise HTTPException(status_code=400, detail="URL обязателен")
    result = await probe_health(probe)
    if body.url.strip():
        result["configured_url"] = body.url.strip()
    return result


@app.post("/api/check/discovery")
async def check_discovery(body: CheckUrlBody):
    probe = internal_probe_url("discovery", body.url) if body.url else internal_probe_url("discovery", "")
    if not probe:
        raise HTTPException(status_code=400, detail="Discovery URL обязателен")
    result = await probe_discovery(probe)
    if body.url.strip():
        result["configured_url"] = body.url.strip()
    return result


@app.post("/api/check/setup")
async def check_setup(body: CheckSetupBody):
    """Probe all configured node URLs from the setup form."""
    checks: list[dict] = []
    if body.discovery_node_url.strip():
        d = await probe_discovery(internal_probe_url("discovery", body.discovery_node_url))
        d["label"] = "Discovery"
        d["key"] = "discovery"
        d["configured_url"] = body.discovery_node_url.strip()
        checks.append(d)
    for label, key, url, enabled in (
        ("Home", "home", body.home_node_public_url, True),
        ("Storage", "storage", body.storage_node_url, True),
        ("Media", "media", body.media_node_public_url, body.check_media),
        ("Relay", "relay", body.relay_node_public_url, body.check_relay),
    ):
        if not enabled:
            continue
        if url and url.strip():
            probe = internal_probe_url(key, url.strip())
            r = await probe_health(probe)
            r["configured_url"] = url.strip()
            r["label"] = label
            r["key"] = key
            checks.append(r)
    ok = sum(1 for c in checks if c.get("ok"))
    return {
        "checks": checks,
        "summary": f"{ok}/{len(checks)} доступны",
        "all_ok": ok == len(checks) and len(checks) > 0,
    }


@app.post("/api/check/media")
async def check_media_node(body: CheckUrlBody | None = None):
    media_url = (body.url if body and body.url.strip() else "") or os.environ.get(
        "MEDIA_NODE_URL", "http://media-node:8004"
    )
    result = await probe_media_admin(media_url.strip())
    result["label"] = "Media Node"
    return result


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


@app.get("/api/services/status")
def get_services_status():
    return services_status()


@app.post("/api/services/{service_name}/{action}")
def post_service_action(service_name: str, action: str):
    try:
        return service_action(service_name, action)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e)) from e
    except RuntimeError as e:
        raise HTTPException(status_code=503, detail=str(e)) from e


@app.post("/api/services/apply-config")
def post_apply_config(body: ServiceActionBody | None = None):
    try:
        return apply_config_restart(body.services if body else None)
    except RuntimeError as e:
        raise HTTPException(status_code=503, detail=str(e)) from e


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


@app.get("/nodes")
def nodes_page():
    return FileResponse(ADMIN_STATIC / "nodes.html")


@app.get("/vuln")
def vuln_page():
    return FileResponse(ADMIN_STATIC / "vuln.html")


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
    headers = {
        "X-Discovery-Admin-Secret": secret,
        "X-Operator-Id": request.headers.get("X-Operator-Id", "operator"),
    }
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
