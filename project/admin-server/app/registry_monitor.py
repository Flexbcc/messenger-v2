"""Authenticated server-side bridge from the admin UI to Discovery control-plane."""

from urllib.parse import quote

import httpx
from fastapi import APIRouter, HTTPException, Request

from app.config_io import read_env_config
from app.registry_metrics import collect_registry_metrics, collect_transport_summary


router = APIRouter()


def _discovery_admin_context() -> tuple[str, dict[str, str]]:
    cfg = read_env_config()
    secret = (cfg.discovery_admin_secret or "").strip()
    if not secret:
        raise HTTPException(
            status_code=503,
            detail="DISCOVERY_ADMIN_SECRET is required for registry administration",
        )
    return cfg.discovery_node_url.rstrip("/"), {
        "X-Discovery-Admin-Secret": secret,
    }


async def _discovery_request(
    method: str,
    path: str,
    *,
    timeout: float = 15.0,
    params: dict | None = None,
    json_body: dict | None = None,
    extra_headers: dict[str, str] | None = None,
) -> httpx.Response:
    base_url, headers = _discovery_admin_context()
    if extra_headers:
        headers.update(extra_headers)
    try:
        async with httpx.AsyncClient(
            timeout=timeout,
            follow_redirects=False,
            trust_env=False,
        ) as client:
            response = await client.request(
                method,
                f"{base_url}{path}",
                params=params,
                json=json_body,
                headers=headers,
            )
            response.raise_for_status()
            return response
    except httpx.HTTPStatusError as exc:
        raise HTTPException(
            status_code=exc.response.status_code,
            detail=exc.response.text,
        ) from exc
    except httpx.RequestError as exc:
        raise HTTPException(
            status_code=502,
            detail=f"Cannot reach discovery: {exc}",
        ) from exc


@router.get("/api/monitor/registry/nodes")
@router.get("/api/monitor/registry/nodes/all")
async def monitor_registry_nodes():
    response = await _discovery_request("GET", "/admin/registry/nodes")
    return response.json()


@router.get("/api/monitor/registry/metrics")
async def monitor_registry_metrics():
    response = await _discovery_request("GET", "/admin/registry/nodes")
    nodes = response.json().get("nodes") or []
    try:
        metrics = await collect_registry_metrics(nodes)
    except Exception as exc:
        print(
            f"[admin] registry metrics failed: {type(exc).__name__}: {exc}",
            flush=True,
        )
        return {
            "nodes": nodes,
            "count": len(nodes),
            "metrics_error": f"{type(exc).__name__}: {exc}",
        }
    return {"nodes": metrics, "count": len(metrics)}


@router.get("/api/monitor/registry/transport-summary")
async def monitor_registry_transport_summary():
    response = await _discovery_request("GET", "/admin/registry/nodes")
    nodes = response.json().get("nodes") or []
    return await collect_transport_summary(nodes)


@router.get("/api/monitor/audit/history")
async def monitor_audit_history(limit: int = 100):
    if not 1 <= limit <= 1000:
        raise HTTPException(status_code=400, detail="limit must be between 1 and 1000")
    response = await _discovery_request(
        "GET",
        "/admin/audit/history",
        params={"limit": limit},
    )
    return response.json()


@router.get("/api/monitor/registry/promotion-candidates")
async def monitor_promotion_candidates():
    response = await _discovery_request(
        "GET", "/admin/registry/promotion-candidates", timeout=10.0
    )
    return response.json()


async def _change_trust_level(node_id: str, action: str, request: Request):
    encoded_node_id = quote(node_id, safe="")
    body: dict = {}
    if request.headers.get("content-type", "").startswith("application/json"):
        try:
            candidate = await request.json()
        except ValueError as exc:
            raise HTTPException(status_code=400, detail="Invalid JSON body") from exc
        if not isinstance(candidate, dict):
            raise HTTPException(status_code=400, detail="JSON body must be an object")
        body = candidate
    response = await _discovery_request(
        "POST",
        f"/admin/registry/nodes/{encoded_node_id}/{action}",
        timeout=10.0,
        json_body=body,
        extra_headers={
            "X-Operator-Id": request.headers.get("X-Operator-Id", "operator")[:128]
        },
    )
    return response.json()


@router.post("/api/monitor/registry/nodes/{node_id}/promote")
async def monitor_promote_node(node_id: str, request: Request):
    return await _change_trust_level(node_id, "promote", request)


@router.post("/api/monitor/registry/nodes/{node_id}/demote")
async def monitor_demote_node(node_id: str, request: Request):
    return await _change_trust_level(node_id, "demote", request)
