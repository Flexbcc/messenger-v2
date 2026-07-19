"""Reverse proxy to internal Operator Admin (main-node :9205/ops)."""
from __future__ import annotations

import os

import httpx
from fastapi import Request
from starlette.responses import Response

OPS_ADMIN_URL = os.environ.get("OPS_ADMIN_URL", "").rstrip("/")
HOP_BY_HOP = frozenset(
    {"connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "te", "trailers", "transfer-encoding", "upgrade"}
)


async def proxy_to_ops_admin(request: Request, subpath: str = "") -> Response:
    if not OPS_ADMIN_URL:
        return Response(
            content='{"detail":"Operator Console not configured (OPS_ADMIN_URL)"}',
            status_code=503,
            media_type="application/json",
        )
    path = f"/{subpath}" if subpath else "/"
    url = f"{OPS_ADMIN_URL}{path}"
    if request.url.query:
        url = f"{url}?{request.url.query}"

    headers = {
        k: v
        for k, v in request.headers.items()
        if k.lower() not in ("host", "content-length")
    }

    async with httpx.AsyncClient(timeout=120.0) as client:
        upstream = await client.request(
            request.method,
            url,
            headers=headers,
            content=await request.body(),
        )

    out_headers = {
        k: v for k, v in upstream.headers.items() if k.lower() not in HOP_BY_HOP
    }
    return Response(content=upstream.content, status_code=upstream.status_code, headers=out_headers)
