"""Gateway Node — public client entry point (spec/0606_GATEWAY_NODE.md, ADR-0010)."""
import asyncio
import html
import json
import os
import time
from pathlib import Path
from typing import Optional
from urllib.parse import quote

import hmac

import httpx
from fastapi import FastAPI, Header, HTTPException, Query, Request
from fastapi.middleware.cors import CORSMiddleware
from shared.security.cors_config import client_allowed_origins
from fastapi.responses import HTMLResponse, JSONResponse
from pydantic import BaseModel, Field
from starlette.middleware.base import BaseHTTPMiddleware

from app.config import settings, validate_security_configuration
from app.invites import create_invite, init_db as init_invites_db, peek_invite, purge_expired, redeem_invite
from app.mtls import (
    ALLOWED_GATEWAY_CLIENT_FINGERPRINTS,
    GATEWAY_MTLS_MODE,
    GATEWAY_TLS_ENABLED,
    GATEWAY_TLS_PORT,
    client_fingerprint_allowed,
    mtls_required_for_path,
    normalize_fingerprint,
    server_cert_fingerprint,
    trusted_proxy,
)
from app.node_registration import start_node_registration
from shared.mesh.install import install_mesh
from shared.security.relay_challenge_receiver import install_relay_challenge_receiver
from shared.security.body_limit import RequestBodyLimitMiddleware
from app.fed_security import get_federation_security

app = FastAPI(title="Gateway Node", version="0.2.0")
install_relay_challenge_receiver(app, get_federation_security)

app.add_middleware(
    RequestBodyLimitMiddleware,
    path_prefixes=("/",),
    max_body_bytes=64 * 1024,
    require_federation_headers=False,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=client_allowed_origins(),
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
        if not trusted_proxy(request.headers.get("X-Gateway-MTLS-Proxy-Secret")):
            return JSONResponse(
                status_code=403,
                content={"detail": "trusted mTLS terminator required"},
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

_discovery_request_count = 0


@app.on_event("startup")
async def on_startup():
    validate_security_configuration()
    init_invites_db()
    purge_expired()
    start_node_registration()


@app.on_event("shutdown")
async def on_shutdown():
    from app.node_registration import stop_node_registration
    await stop_node_registration()


class InviteCreateRequest(BaseModel):
    cluster_id: Optional[str] = Field(None, min_length=1, max_length=128)
    ttl_seconds: Optional[int] = Field(None, ge=30, le=86400)
    label: Optional[str] = Field(None, max_length=256)


def _invite_auth_ok(secret_header: Optional[str]) -> bool:
    expected = settings.invite_secret
    if not expected:
        return False
    if not secret_header:
        return False
    return hmac.compare_digest(secret_header, expected)


def _join_url(token: str) -> str:
    base = settings.public_url.rstrip("/")
    return f"{base}/join?t={quote(token, safe='')}"


async def _bootstrap_payload(cluster_id: str, strategy: str = "nearest") -> dict:
    routing = await client_routing(cluster_id=cluster_id, strategy=strategy)
    preferred = routing.get("preferred") or {}
    home_url = preferred.get("home_url")
    media_url = preferred.get("media_url")
    if not isinstance(home_url, str) or not isinstance(media_url, str):
        raise HTTPException(
            status_code=503,
            detail="No trusted bootstrap route is currently available",
        )
    return {
        "cluster_id": cluster_id,
        "gateway_url": settings.public_url,
        "discovery_url": routing.get("discovery_url") or settings.discovery_public_url,
        "discovery_urls": routing.get("discovery_urls")
        or list(settings.discovery_public_urls),
        "home_url": home_url,
        "media_url": media_url,
        "routing": routing,
    }


@app.get("/health")
def health():
    from app.node_registration import node_registration_status, runtime_node_id
    return {
        "status": "ok",
        "node_role": "gateway",
        "node_id": runtime_node_id(),
        "node_alias": settings.node_id,
        "load": {"discovery_requests": _discovery_request_count},
        "runtime": {"capabilities": settings.capabilities, "registration": node_registration_status()},
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
    global _discovery_request_count
    last_error: Exception | None = None
    async with httpx.AsyncClient(
        timeout=10.0, follow_redirects=False, trust_env=False
    ) as client:
        for origin in settings.discovery_urls:
            try:
                response = await client.get(
                    f"{origin.rstrip('/')}{path}", params=params
                )
                _discovery_request_count += 1
                if response.status_code < 500:
                    return response
                last_error = RuntimeError(
                    f"Discovery returned HTTP {response.status_code}"
                )
            except httpx.RequestError as exc:
                last_error = exc
    raise HTTPException(
        status_code=502,
        detail=f"No Discovery source is reachable ({type(last_error).__name__ if last_error else 'none configured'})",
    )


async def _ping_node(node_url: str) -> Optional[float]:
    t0 = time.perf_counter()
    try:
        async with httpx.AsyncClient(
            timeout=2.5, follow_redirects=False, trust_env=False
        ) as client:
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
    cluster_id: str = Query("default", min_length=1, max_length=128),
    strategy: str = Query("all", pattern="^(all|nearest)$"),
):
    """
    Client-facing bootstrap: gateways, media nodes, discovery URL.
    Does not expose untrusted nodes — Discovery filters trust_status=trusted.
    """
    resp = await _discovery_get("/registry/nodes", params={"cluster_id": cluster_id})
    resp.raise_for_status()
    nodes = resp.json().get("nodes", [])
    def certified(node: dict, capability: str) -> bool:
        return (
            node.get("status") == "online"
            and node.get("trust_status") == "trusted"
            and node.get("node_identity_status") == "valid"
            and node.get("node_advertisement_status") == "valid"
            and node.get("capability_certificate_status") == "valid"
            and capability in node.get("certified_capabilities", [])
            and node.get("node_url", "").rstrip("/")
            in {url.rstrip("/") for url in node.get("advertised_endpoints", [])}
        )
    gateways = [
        {"node_id": n["node_id"], "url": n["node_url"]}
        for n in nodes
        if certified(n, "gateway")
    ]
    media_nodes = [
        {"node_id": n["node_id"], "url": n["node_url"]}
        for n in nodes
        if certified(n, "media")
    ]
    home_nodes = [
        {"node_id": n["node_id"], "url": n["node_url"]}
        for n in nodes
        if certified(n, "home")
    ]
    ranked_gateways = await _rank_nodes(gateways)
    ranked_media = await _rank_nodes(media_nodes)
    ranked_home = await _rank_nodes(home_nodes)

    payload = {
        "cluster_id": cluster_id,
        "discovery_url": settings.discovery_public_url,
        "discovery_urls": list(settings.discovery_public_urls),
        "strategy": strategy,
        "gateways": ranked_gateways,
        "media_nodes": ranked_media,
        "home_nodes": ranked_home,
    }
    if strategy == "nearest":
        payload["preferred"] = {
            "gateway_url": (ranked_gateways[0]["url"] if ranked_gateways else None),
            "media_url": (ranked_media[0]["url"] if ranked_media else None),
            "home_url": (ranked_home[0]["url"] if ranked_home else None),
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


@app.post("/gateway/invite/create")
async def invite_create(
    body: InviteCreateRequest,
    x_gateway_invite_secret: Optional[str] = Header(None, alias="X-Gateway-Invite-Secret"),
):
    if not _invite_auth_ok(x_gateway_invite_secret):
        raise HTTPException(status_code=403, detail="Invite API disabled or invalid secret")
    cluster_id = body.cluster_id or settings.cluster_id
    ttl = body.ttl_seconds or settings.invite_ttl_seconds
    row = create_invite(cluster_id=cluster_id, ttl_seconds=ttl, label=body.label, created_by="operator")
    token = row["token"]
    return {
        **row,
        "join_url": _join_url(token),
        "qr_payload": _join_url(token),
    }


@app.get("/gateway/invite/redeem/{token}")
async def invite_redeem(token: str):
    meta = redeem_invite(token)
    if not meta:
        raise HTTPException(status_code=404, detail="Invite invalid, expired, or already used")
    payload = await _bootstrap_payload(meta["cluster_id"])
    payload["invite_label"] = meta.get("label")
    return payload


@app.get("/join")
async def join_landing(t: str = Query(..., min_length=8, max_length=512)):
    """Browser landing for QR — does not consume the token (app redeems via API)."""
    meta = peek_invite(t)
    if not meta:
        return HTMLResponse(
            "<h1>Invite недействителен</h1><p>Срок истёк или уже использован.</p>",
            status_code=404,
        )
    join_url = _join_url(t)
    response = HTMLResponse(
        f"""<!DOCTYPE html><html lang="ru"><head><meta charset="utf-8">
        <title>Подключение к Messenger</title></head><body>
        <h1>Приглашение в сеть</h1>
        <p>Кластер: <code>{html.escape(str(meta.get("cluster_id", "")))}</code></p>
        <p>Откройте приложение Messenger → «Подключиться к сети» → вставьте ссылку или отсканируйте QR.</p>
        <p><code>{html.escape(join_url)}</code></p>
        </body></html>"""
    )
    response.headers["Content-Security-Policy"] = "default-src 'none'; style-src 'unsafe-inline'"
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["Referrer-Policy"] = "no-referrer"
    return response


RELEASES_MANIFEST = Path(
    os.environ.get(
        "RELEASES_MANIFEST",
        str(Path(__file__).resolve().parents[1] / "releases" / "clients" / "manifest.json"),
    )
)
RELEASES_MANIFEST_MAX_BYTES = 512 * 1024


@app.get("/releases/clients/manifest.json")
async def client_releases_manifest():
    """Bounded release metadata for client update discovery."""
    try:
        manifest_size = RELEASES_MANIFEST.stat().st_size
    except (FileNotFoundError, OSError) as exc:
        raise HTTPException(status_code=404, detail="Release manifest not deployed")
    if not 0 < manifest_size <= RELEASES_MANIFEST_MAX_BYTES:
        raise HTTPException(status_code=500, detail="Release manifest is invalid")
    try:
        raw = RELEASES_MANIFEST.read_bytes()
        if len(raw) != manifest_size or len(raw) > RELEASES_MANIFEST_MAX_BYTES:
            raise ValueError("release manifest changed while being read")
        data = json.loads(raw.decode("utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError, ValueError) as exc:
        raise HTTPException(status_code=500, detail="Release manifest is invalid") from exc
    if not isinstance(data, dict):
        raise HTTPException(status_code=500, detail="Release manifest is invalid")
    return JSONResponse(
        content=data,
        headers={
            "Cache-Control": "public, max-age=300",
            "X-Content-Type-Options": "nosniff",
        },
    )


install_mesh(
    app,
    discovery_url=settings.discovery_url,
    node_id=settings.node_id,
    cluster_id=settings.cluster_id,
)
