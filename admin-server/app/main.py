import json
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
from app import operator_transport
from app import operator_ssh
from pydantic import BaseModel

ADMIN_PANEL_SECRET = os.environ.get("ADMIN_PANEL_SECRET", "")

# «project» — панель на сервере (устаревающий режим)
# «operator» — пульт на машине оператора, ходит к нодам через mTLS
ADMIN_VARIANT = os.environ.get("ADMIN_VARIANT", "project")

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

# ---------------------------------------------------------------------------
# БЕЗОПАСНОСТЬ
#
# Админка управляет всей федерацией: конфиги, секреты, promote/demote нод,
# рестарт контейнеров. Доступ к ней = полный контроль над кластером.
# Она НЕ ДОЛЖНА быть доступна клиентским нодам или из внешней сети.
#
# Три уровня защиты:
#   1. Сетевой   — bind только на 127.0.0.1 (в docker-compose)
#   2. CORS      — запросы только с самой панели, не с чужих сайтов
#   3. Секрет    — X-Admin-Panel-Secret на всех /api/ запросах
# ---------------------------------------------------------------------------

# Порт, на котором мы реально слушаем — нужен для сборки списка origins
_ADMIN_PORT = os.environ.get("ADMIN_PORT", "9200")

# Разрешаем только локальные origin'ы. Раньше здесь было "*", из-за чего
# ЛЮБОЙ сайт, открытый в браузере оператора, мог слать запросы на
# http://127.0.0.1:<порт> и управлять кластером.
_ALLOWED_ORIGINS: list[str] = []

# Дополнительные origin'ы — например при доступе через reverse-proxy с доменом
_extra_origins = os.environ.get("ADMIN_ALLOWED_ORIGINS", "").strip()
if _extra_origins:
    _ALLOWED_ORIGINS.extend(o.strip() for o in _extra_origins.split(",") if o.strip())

# Любой localhost-порт. Перечислять порты поимённо нельзя: внешний порт
# (проброшенный docker'ом) часто не совпадает с внутренним, и панель
# начинала блокировать собственный браузер.
#
# Безопасность при этом не страдает: разрешены только адреса самой машины.
# Чужой сайт из интернета под этот шаблон не подойдёт, а именно от него
# и защищались, убирая прежнее allow_origins=["*"].
_LOCAL_ORIGIN_RE = r"^https?://(localhost|127\.0\.0\.1|\[::1\])(:\d+)?$"

app.add_middleware(
    CORSMiddleware,
    allow_origins=_ALLOWED_ORIGINS,
    allow_origin_regex=_LOCAL_ORIGIN_RE,
    allow_credentials=True,
    allow_methods=["GET", "POST", "PUT", "DELETE", "OPTIONS"],
    allow_headers=["Content-Type", "X-Admin-Panel-Secret", "X-Discovery-Admin-Secret"],
)


# Пути, доступные без секрета:
#   /health          — healthcheck докера
#   /api/enrollment/ — используется нодами при вступлении в кластер,
#                      защищён собственным enrollment-токеном
_PUBLIC_API_PREFIXES = ("/api/enrollment/",)


def _is_local_request(request: Request) -> bool:
    """
    Запрос пришёл с самой машины?

    ВНИМАНИЕ: внутри контейнера этому верить нельзя. Docker пробрасывает
    порт через NAT, поэтому запрос из браузера по 127.0.0.1:9210 приходит
    в контейнер с адреса docker-моста (172.x.x.x), а не с loopback.

    Поэтому функция используется только как подсказка в диагностике,
    а не как средство защиты. Ограничение доступа обеспечивается
    привязкой порта к 127.0.0.1 в docker-compose — это делает ядро,
    и обойти это из сети нельзя.
    """
    client = request.client
    if client is None:
        return False
    return client.host in ("127.0.0.1", "::1", "localhost")


@app.middleware("http")
async def admin_panel_guard(request: Request, call_next):
    path = request.url.path

    # Не /api/ — статика панели, отдаём как есть
    if not path.startswith("/api/"):
        return await call_next(request)

    # Публичные эндпоинты (enrollment нод)
    if any(path.startswith(p) for p in _PUBLIC_API_PREFIXES):
        return await call_next(request)

    # Preflight — пропускаем, CORSMiddleware сам разберётся
    if request.method == "OPTIONS":
        return await call_next(request)

    if ADMIN_PANEL_SECRET:
        # Секрет задан — требуем его на ВСЕХ запросах, включая GET.
        # Раньше проверялись только PUT/POST/DELETE, из-за чего
        # GET /api/config и /api/monitor/* отдавали топологию федерации,
        # список нод и пути к конфигам вообще без авторизации.
        token = request.headers.get("X-Admin-Panel-Secret", "")
        if not secrets_mod.compare_digest(token, ADMIN_PANEL_SECRET):
            return Response(
                content='{"detail":"Admin panel authentication required"}',
                status_code=401,
                media_type="application/json",
                headers={"WWW-Authenticate": "X-Admin-Panel-Secret"},
            )
    # Секрет не задан — пускаем. Защита в этом случае обеспечивается тем,
    # что порт привязан к 127.0.0.1 (см. docker-compose): снаружи машины
    # до него не достучаться.
    #
    # Раньше здесь стояла дополнительная проверка на loopback, но в
    # контейнере она отклоняла все запросы: Docker пробрасывает порт через
    # NAT, и клиентский адрес выглядит как 172.x.x.x. Панель отвечала 403
    # на собственный браузер.

    return await call_next(request)


@app.exception_handler(Exception)
async def _unhandled_exception_handler(request: Request, exc: Exception):
    """
    Любая необработанная ошибка — в виде JSON.

    По умолчанию FastAPI отдаёт «Internal Server Error» простым текстом,
    и фронт спотыкается на разборе: «Unexpected token 'I'». Причина при
    этом остаётся только в логах контейнера.

    Здесь возвращается тот же 500, но с текстом ошибки — панель показывает
    её на месте, вместо загадочной жалобы на JSON.
    """
    import traceback

    tb = traceback.format_exc()
    print(f"[admin] необработанная ошибка на {request.url.path}:\n{tb}", flush=True)

    return Response(
        content=json.dumps(
            {
                "detail": f"{type(exc).__name__}: {exc}",
                "path": request.url.path,
            },
            ensure_ascii=False,
        ),
        status_code=500,
        media_type="application/json",
    )


@app.on_event("startup")
async def _security_banner() -> None:
    """Громко предупредить оператора о небезопасной конфигурации."""
    if ADMIN_PANEL_SECRET:
        print("[admin] ✓ ADMIN_PANEL_SECRET задан — /api/ защищён")
    else:
        print("=" * 70, flush=True)
        print("[admin] ⚠️  ADMIN_PANEL_SECRET НЕ ЗАДАН", flush=True)
        print("[admin]", flush=True)
        print("[admin] Панель работает БЕЗ пароля.", flush=True)
        print("[admin] Это допустимо, только если порт привязан к 127.0.0.1", flush=True)
        print("[admin] (проверьте секцию ports в docker-compose).", flush=True)
        print("[admin]", flush=True)
        print("[admin] Для доступа с другой машины:", flush=True)
        print("[admin]   1) задайте ADMIN_PANEL_SECRET, либо", flush=True)
        print("[admin]   2) используйте SSH-туннель:", flush=True)
        print(f"[admin]      ssh -L {_ADMIN_PORT}:127.0.0.1:{_ADMIN_PORT} user@host", flush=True)
        print("=" * 70, flush=True)

    extra = ", ".join(_ALLOWED_ORIGINS) if _ALLOWED_ORIGINS else "—"
    print(f"[admin] CORS: любой localhost-порт; дополнительно: {extra}", flush=True)


@app.get("/health")
def health():
    return {
        "status": "ok",
        "node_role": "admin",
        "variant": ADMIN_VARIANT,
        "load": {
            "env_exists": ENV_PATH.exists(),
            "storage_config_exists": STORAGE_CONFIG_PATH.exists(),
            "panel_auth": bool(ADMIN_PANEL_SECRET),
        },
    }


###############################################################################
# РЕЖИМ ПУЛЬТА ОПЕРАТОРА (ADMIN_VARIANT=operator)
#
# Пульт запускается на машине оператора и ходит к нодам через mTLS-шлюз.
# На серверах админки при этом нет вообще — их админ-порты закрыты.
#
# Отличия от режима «на сервере»:
#   • нет доступа к локальным .env и docker.sock — управляем по сети
#   • телеметрия чужих нод берётся из discovery (heartbeat), а не с самих нод
#   • конфигурация и перезапуск — только для нод из OPERATOR_OWNED_NODES
###############################################################################


@app.get("/api/operator/status")
async def operator_status():
    """Готовность обоих каналов пульта: mTLS и SSH."""
    return {
        "variant": ADMIN_VARIANT,
        "mtls": {
            "certificates": operator_transport.describe_certificates(),
            "gateways": {
                "discovery": operator_transport.DISCOVERY_GATEWAY or None,
                "home": operator_transport.HOME_GATEWAY or None,
            },
        },
        "ssh": operator_ssh.describe(),
        "owned_nodes": sorted(operator_transport.OWNED_NODES),
    }


@app.get("/api/operator/nodes")
async def operator_nodes():
    """
    Все ноды федерации с телеметрией.

    Данные берутся из discovery: ноды сами присылают метрики в heartbeat.
    К чужим нодам пульт не обращается — только к реестру.
    """
    try:
        resp = await operator_transport.discovery_request(
            "GET", "/admin/registry/nodes", params={"include_untrusted": "true"}
        )
        resp.raise_for_status()
        data = resp.json()
    except operator_transport.OperatorTransportError as e:
        raise HTTPException(status_code=503, detail=str(e)) from e
    except httpx.HTTPStatusError as e:
        raise HTTPException(status_code=e.response.status_code, detail=e.response.text) from e

    # Помечаем свои ноды — фронт покажет для них больше действий
    nodes = data.get("nodes", data if isinstance(data, list) else [])
    for node in nodes:
        if isinstance(node, dict):
            node["is_owned"] = operator_transport.is_owned(node.get("node_id", ""))

    return data


@app.post("/api/operator/registry/{node_id}/{action}")
async def operator_registry_action(node_id: str, action: str, body: dict | None = None):
    """
    Операции реестра федерации: approve, suspend, reinstate, promote, demote.

    Применимы к ЛЮБОЙ ноде, включая чужие — это право оператора федерации
    решать, кто в ней состоит. Внутренностей чужой ноды это не касается.
    """
    allowed = {"approve", "suspend", "reinstate", "compromise", "promote", "demote"}
    if action not in allowed:
        raise HTTPException(
            status_code=400,
            detail=f"Неизвестное действие «{action}». Доступны: {', '.join(sorted(allowed))}",
        )

    try:
        resp = await operator_transport.discovery_request(
            "POST", f"/admin/registry/nodes/{node_id}/{action}", json_body=body or {}
        )
        resp.raise_for_status()
        return resp.json()
    except operator_transport.OperatorTransportError as e:
        raise HTTPException(status_code=503, detail=str(e)) from e
    except httpx.HTTPStatusError as e:
        raise HTTPException(status_code=e.response.status_code, detail=e.response.text) from e


@app.get("/api/operator/audit")
async def operator_audit(limit: int = 100):
    """Журнал админ-действий из discovery."""
    try:
        resp = await operator_transport.discovery_request(
            "GET", "/admin/audit/history", params={"limit": limit}
        )
        resp.raise_for_status()
        return resp.json()
    except operator_transport.OperatorTransportError as e:
        raise HTTPException(status_code=503, detail=str(e)) from e
    except httpx.HTTPStatusError as e:
        raise HTTPException(status_code=e.response.status_code, detail=e.response.text) from e


@app.get("/api/operator/my-node/monitor")
async def operator_my_node_monitor(path: str = "snapshot"):
    """
    Телеметрия СВОЕЙ home-ноды напрямую через её шлюз.

    Здесь данных больше, чем в heartbeat: он присылает сводку раз в интервал,
    а тут — актуальный срез.
    """
    safe = {"snapshot", "federation", "storage", "devices"}
    if path not in safe:
        raise HTTPException(
            status_code=400, detail=f"Недоступный раздел. Доступны: {', '.join(sorted(safe))}"
        )
    try:
        resp = await operator_transport.home_request("GET", f"/monitor/{path}")
        resp.raise_for_status()
        return resp.json()
    except operator_transport.OperatorTransportError as e:
        raise HTTPException(status_code=503, detail=str(e)) from e
    except httpx.HTTPStatusError as e:
        raise HTTPException(status_code=e.response.status_code, detail=e.response.text) from e


###############################################################################
# SSH-КАНАЛ — обслуживание своих серверов
#
# Деплой, перезапуск контейнеров, логи. Работает только там, где есть
# root-доступ, то есть на своих машинах. Чужие ноды сюда не попадают:
# их обслуживают владельцы.
###############################################################################


@app.get("/api/operator/services")
async def operator_services():
    """Состояние контейнеров на своих серверах."""
    try:
        return {"services": await operator_ssh.services_status()}
    except operator_ssh.SshUnavailable as e:
        raise HTTPException(status_code=503, detail=str(e)) from e


@app.post("/api/operator/services/{service}/restart")
async def operator_restart_service(service: str):
    """Перезапустить контейнер на своём сервере."""
    try:
        return await operator_ssh.restart_service(service)
    except operator_ssh.SshUnavailable as e:
        raise HTTPException(status_code=400, detail=str(e)) from e


@app.get("/api/operator/services/{service}/logs")
async def operator_service_logs(service: str, lines: int = 200):
    """Последние строки лога контейнера."""
    try:
        return await operator_ssh.service_logs(service, lines=lines)
    except operator_ssh.SshUnavailable as e:
        raise HTTPException(status_code=400, detail=str(e)) from e


@app.get("/api/operator/deploy/status")
async def operator_deploy_status():
    """Что развёрнуто: git-ревизия, последний деплой, состояние вебхука."""
    try:
        return await operator_ssh.deploy_status()
    except operator_ssh.SshUnavailable as e:
        raise HTTPException(status_code=503, detail=str(e)) from e


@app.post("/api/operator/deploy/pull")
async def operator_deploy_pull(body: dict | None = None):
    """
    Раскатать на сервере то, что уже в репозитории.

    Пульт не публикует код — только разворачивает. Публикация остаётся
    обычным git push, чтобы изменения проходили через историю репозитория.
    """
    alias = (body or {}).get("host")
    try:
        return await operator_ssh.deploy_pull(alias)
    except operator_ssh.SshUnavailable as e:
        raise HTTPException(status_code=503, detail=str(e)) from e


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
    # Сбор метрик опрашивает каждую ноду. Если одна отвечает неожиданно,
    # это не повод ронять всю страницу — отдаём список нод без метрик.
    try:
        metrics = await collect_registry_metrics(nodes)
    except Exception as e:
        print(f"[admin] сбор метрик не удался: {type(e).__name__}: {e}", flush=True)
        return {
            "nodes": nodes,
            "count": len(nodes),
            "metrics_error": f"{type(e).__name__}: {e}",
        }
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
    # В режиме пульта корень открывает страницу оператора: серверная
    # панель управления конфигами здесь неприменима — локальных .env
    # и docker.sock у пульта нет.
    if ADMIN_VARIANT == "operator":
        return FileResponse(ADMIN_STATIC / "operator.html")
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


@app.get("/audit")
def audit_page():
    return FileResponse(ADMIN_STATIC / "audit.html")


@app.get("/operator")
def operator_page():
    """Страница пульта — объединяет оба канала: mTLS и SSH."""
    return FileResponse(ADMIN_STATIC / "operator.html")


@app.get("/health-dashboard")
def health_dashboard_page():
    return FileResponse(ADMIN_STATIC / "health.html")


@app.get("/api/monitor/audit/history")
async def monitor_audit_history(limit: int = 100):
    """
    Журнал админ-действий — проксируем в discovery.

    Сам лог живёт в discovery-node (/admin/audit/history) и требует
    DISCOVERY_ADMIN_SECRET. Панель не должна знать этот секрет в браузере,
    поэтому запрос идёт через сервер.
    """
    cfg = read_env_config()
    url = f"{cfg.discovery_node_url.rstrip('/')}/admin/audit/history"
    discovery_secret = os.environ.get("DISCOVERY_ADMIN_SECRET", "")
    if not discovery_secret:
        raise HTTPException(
            status_code=503,
            detail="DISCOVERY_ADMIN_SECRET is not configured on the admin server",
        )
    try:
        async with httpx.AsyncClient(timeout=15.0) as client:
            resp = await client.get(
                url,
                params={"limit": limit},
                headers={"X-Discovery-Admin-Secret": discovery_secret},
            )
            resp.raise_for_status()
            return resp.json()
    except httpx.HTTPStatusError as e:
        raise HTTPException(status_code=e.response.status_code, detail=e.response.text) from e
    except httpx.RequestError as e:
        raise HTTPException(status_code=502, detail=f"Cannot reach discovery: {e}") from e


@app.get("/api/monitor/registry/nodes/all")
async def monitor_registry_nodes_all():
    """All nodes (trusted + pending) with metrics from discovery."""
    cfg = read_env_config()
    url = f"{cfg.discovery_node_url.rstrip('/')}/admin/registry/nodes"
    try:
        async with httpx.AsyncClient(timeout=15.0) as client:
            resp = await client.get(
                url,
                headers={"X-Discovery-Admin-Secret": cfg.discovery_admin_secret or ""},
            )
            resp.raise_for_status()
            return resp.json()
    except httpx.HTTPStatusError as e:
        raise HTTPException(status_code=e.response.status_code, detail=e.response.text) from e
    except httpx.RequestError as e:
        raise HTTPException(status_code=502, detail=f"Cannot reach discovery: {e}") from e


@app.get("/api/monitor/registry/promotion-candidates")
async def monitor_promotion_candidates():
    cfg = read_env_config()
    url = f"{cfg.discovery_node_url.rstrip('/')}/admin/registry/promotion-candidates"
    try:
        async with httpx.AsyncClient(timeout=10.0) as client:
            resp = await client.get(
                url,
                headers={"X-Discovery-Admin-Secret": cfg.discovery_admin_secret or ""},
            )
            resp.raise_for_status()
            return resp.json()
    except httpx.HTTPStatusError as e:
        raise HTTPException(status_code=e.response.status_code, detail=e.response.text) from e
    except httpx.RequestError as e:
        raise HTTPException(status_code=502, detail=f"Cannot reach discovery: {e}") from e


@app.post("/api/monitor/registry/nodes/{node_id}/promote")
async def monitor_promote_node(node_id: str, request: Request):
    cfg = read_env_config()
    url = f"{cfg.discovery_node_url.rstrip('/')}/admin/registry/nodes/{node_id}/promote"
    body = await request.json() if request.headers.get("content-type", "").startswith("application/json") else {}
    try:
        async with httpx.AsyncClient(timeout=10.0) as client:
            resp = await client.post(
                url,
                json=body,
                headers={
                    "X-Discovery-Admin-Secret": cfg.discovery_admin_secret or "",
                    "X-Operator-Id": request.headers.get("X-Operator-Id", "operator"),
                },
            )
            resp.raise_for_status()
            return resp.json()
    except httpx.HTTPStatusError as e:
        raise HTTPException(status_code=e.response.status_code, detail=e.response.text) from e
    except httpx.RequestError as e:
        raise HTTPException(status_code=502, detail=f"Cannot reach discovery: {e}") from e


@app.post("/api/monitor/registry/nodes/{node_id}/demote")
async def monitor_demote_node(node_id: str, request: Request):
    cfg = read_env_config()
    url = f"{cfg.discovery_node_url.rstrip('/')}/admin/registry/nodes/{node_id}/demote"
    body = await request.json() if request.headers.get("content-type", "").startswith("application/json") else {}
    try:
        async with httpx.AsyncClient(timeout=10.0) as client:
            resp = await client.post(
                url,
                json=body,
                headers={
                    "X-Discovery-Admin-Secret": cfg.discovery_admin_secret or "",
                    "X-Operator-Id": request.headers.get("X-Operator-Id", "operator"),
                },
            )
            resp.raise_for_status()
            return resp.json()
    except httpx.HTTPStatusError as e:
        raise HTTPException(status_code=e.response.status_code, detail=e.response.text) from e
    except httpx.RequestError as e:
        raise HTTPException(status_code=502, detail=f"Cannot reach discovery: {e}") from e


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
