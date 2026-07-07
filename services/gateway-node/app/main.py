"""Gateway Node — public client entry point (spec/0606_GATEWAY_NODE.md, ADR-0010)."""
import asyncio
import time
from typing import Optional

import httpx
from fastapi import FastAPI, HTTPException, Query, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse, Response
from starlette.middleware.base import BaseHTTPMiddleware

from app.config import settings
from app.mtls import (
    ALLOWED_GATEWAY_CLIENT_FINGERPRINTS,
    GATEWAY_MTLS_MODE,
    GATEWAY_TLS_ENABLED,
    GATEWAY_TLS_PORT,
    client_fingerprint_allowed,
    mtls_required_for_path,
    normalize_fingerprint,
    server_cert_fingerprint,
)
from app.node_registration import start_node_registration

app = FastAPI(title="Gateway Node", version="0.2.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


class MtlsMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next):
        path = request.url.path
        if not mtls_required_for_path(path):
            return await call_next(request)

        fp = normalize_fingerprint(
            request.headers.get("X-Client-Cert-SHA256")
            or request.headers.get("X-Client-Cert-Fingerprint")
        )
        if GATEWAY_MTLS_MODE == "required":
            if not client_fingerprint_allowed(fp):
                return JSONResponse(
                    status_code=403,
                    content={"detail": "mTLS client certificate required (valid fingerprint missing)"},
                )
        elif GATEWAY_MTLS_MODE == "optional" and fp and not client_fingerprint_allowed(fp):
            return JSONResponse(
                status_code=403,
                content={"detail": "Client certificate fingerprint not allowed"},
            )
        return await call_next(request)


app.add_middleware(MtlsMiddleware)

_proxy_count = 0


@app.on_event("startup")
async def on_startup():
    start_node_registration()


@app.get("/health")
def health():
    return {
        "status": "ok",
        "node_role": "gateway",
        "node_id": settings.node_id,
        "load": {"proxied_requests": _proxy_count},
        "mtls": {
            "tls_enabled": GATEWAY_TLS_ENABLED,
            "tls_port": GATEWAY_TLS_PORT if GATEWAY_TLS_ENABLED else None,
            "mtls_mode": GATEWAY_MTLS_MODE,
        },
    }


@app.get("/gateway/mtls/info")
def mtls_info():
    return {
        "tls_enabled": GATEWAY_TLS_ENABLED,
        "tls_port": GATEWAY_TLS_PORT,
        "mtls_mode": GATEWAY_MTLS_MODE,
        "server_cert_fingerprint": server_cert_fingerprint(),
        "allowed_client_fingerprints_count": len(ALLOWED_GATEWAY_CLIENT_FINGERPRINTS),
        "note": "With GATEWAY_TLS_ENABLED=true, clients must present a CA-signed certificate at TLS handshake.",
    }


async def _discovery_get(path: str, *, params: Optional[dict] = None) -> httpx.Response:
    async with httpx.AsyncClient(timeout=10.0) as client:
        return await client.get(f"{settings.discovery_url.rstrip('/')}{path}", params=params)


async def _ping_node(node_url: str) -> Optional[float]:
    t0 = time.perf_counter()
    try:
        async with httpx.AsyncClient(timeout=2.5) as client:
            resp = await client.get(f"{node_url.rstrip('/')}/health")
            resp.raise_for_status()
        return (time.perf_counter() - t0) * 1000.0
    except httpx.HTTPError:
        return None


async def _rank_nodes(nodes: list[dict]) -> list[dict]:
    checks = await asyncio.gather(*[_ping_node(n["url"]) for n in nodes], return_exceptions=False)
    ranked: list[dict] = []
    for node, latency in zip(nodes, checks):
        ranked.append({**node, "latency_ms": latency})
    ranked.sort(key=lambda n: float("inf") if n["latency_ms"] is None else n["latency_ms"])
    return ranked


@app.get("/gateway/routing")
async def client_routing(
    cluster_id: str = Query("default"),
    strategy: str = Query("all", pattern="^(all|nearest)$"),
):
    """
    Client-facing bootstrap: gateways, media nodes, discovery URL.
    Does not expose untrusted nodes — Discovery filters trust_status=trusted.
    """
    resp = await _discovery_get("/registry/nodes", params={"cluster_id": cluster_id})
    resp.raise_for_status()
    nodes = resp.json().get("nodes", [])
    gateways = [
        {"node_id": n["node_id"], "url": n["node_url"]}
        for n in nodes
        if "gateway" in n.get("capabilities", [])
    ]
    media_nodes = [
        {"node_id": n["node_id"], "url": n["node_url"]}
        for n in nodes
        if "media" in n.get("capabilities", [])
    ]
    home_nodes = [
        {"node_id": n["node_id"], "url": n["node_url"]}
        for n in nodes
        if "home" in n.get("capabilities", [])
    ]
    ranked_gateways = await _rank_nodes(gateways)
    ranked_media = await _rank_nodes(media_nodes)
    ranked_home = await _rank_nodes(home_nodes)

    payload = {
        "cluster_id": cluster_id,
        "discovery_url": settings.discovery_public_url,
        "strategy": strategy,
        "gateways": ranked_gateways,
        "media_nodes": ranked_media,
        "home_nodes": ranked_home,
        "defaults": {
            "home_url": settings.default_home_url,
            "media_url": settings.default_media_url,
        },
    }
    if strategy == "nearest":
        payload["preferred"] = {
            "gateway_url": (ranked_gateways[0]["url"] if ranked_gateways else None),
            "media_url": (ranked_media[0]["url"] if ranked_media else settings.default_media_url),
            "home_url": (ranked_home[0]["url"] if ranked_home else settings.default_home_url),
        }
    return payload


@app.get("/gateway/catalog/nodes")
async def catalog_nodes(
    capability: Optional[str] = None,
    cluster_id: Optional[str] = None,
):
    params = {}
    if capability:
        params["capability"] = capability
    if cluster_id:
        params["cluster_id"] = cluster_id
    resp = await _discovery_get("/registry/nodes", params=params or None)
    if resp.status_code >= 400:
        raise HTTPException(status_code=resp.status_code, detail=resp.text)
    return resp.json()


@app.get("/gateway/catalog/users/{user_id}")
async def catalog_users(user_id: str):
    resp = await _discovery_get(f"/registry/users/{user_id}")
    if resp.status_code == 404:
        raise HTTPException(status_code=404, detail="Unknown user_id")
    if resp.status_code >= 400:
        raise HTTPException(status_code=resp.status_code, detail=resp.text)
    return resp.json()


@app.api_route("/gateway/proxy/discovery/{path:path}", methods=["GET", "POST", "PUT", "DELETE"])
async def proxy_discovery(path: str, request: Request):
    global _proxy_count
    url = f"{settings.discovery_url.rstrip('/')}/{path}"
    body = await request.body()
    async with httpx.AsyncClient(timeout=30.0) as client:
        resp = await client.request(request.method, url, content=body, headers=dict(request.headers))
    _proxy_count += 1
    return Response(
        content=resp.content,
        status_code=resp.status_code,
        media_type=resp.headers.get("content-type"),
    )
