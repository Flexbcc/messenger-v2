"""Headless management API for a locally owned OUO node.

This service intentionally has no web UI and is expected to be bound to
loopback or a private VPN interface by the deployment layer.
"""

import base64
import json
import os
from datetime import datetime, timezone
from functools import lru_cache
from pathlib import Path
from typing import Any

from fastapi import FastAPI, Header, HTTPException, Request
from pydantic import BaseModel, Field

from shared.security.keys import load_or_create_signing_key
from shared.security.body_limit import RequestBodyLimitMiddleware
from shared.security.metrics import RateLimiter
from shared.security.owner_management_store import OwnerManagementStore


ROOT_KEY_PATH = os.environ.get("NODE_ROOT_KEY_PATH", "/data/node_root_key")
STATE_PATH = os.environ.get(
    "OWNER_MANAGEMENT_STATE_PATH", "/data/owner_management_state.json"
)


class PairRequest(BaseModel):
    pairing_id: str = Field(min_length=36, max_length=36)
    pairing_secret: str = Field(min_length=32, max_length=128)
    device_public_key: str = Field(min_length=40, max_length=64)


@lru_cache
def get_store() -> OwnerManagementStore:
    return OwnerManagementStore(
        STATE_PATH,
        node_root_signing_key=load_or_create_signing_key(ROOT_KEY_PATH),
    )


def _decode_request_header(value: str) -> dict[str, Any]:
    if not value or len(value) > 8192:
        raise HTTPException(status_code=401, detail="owner request signature required")
    try:
        padding = "=" * (-len(value) % 4)
        raw = base64.urlsafe_b64decode((value + padding).encode("ascii"))
        parsed = json.loads(raw)
    except (UnicodeEncodeError, ValueError, TypeError, json.JSONDecodeError) as exc:
        raise HTTPException(status_code=401, detail="invalid owner request encoding") from exc
    if not isinstance(parsed, dict):
        raise HTTPException(status_code=401, detail="owner request must be an object")
    return parsed


async def _authorize(
    request: Request,
    encoded_request: str,
    *,
    permission: str,
) -> dict[str, Any]:
    body = await request.body()
    signed_request = _decode_request_header(encoded_request)
    result = get_store().authorize_request(
        signed_request,
        permission=permission,
        now=datetime.now(timezone.utc),
        method=request.method,
        path=request.url.path,
        body=body,
    )
    if not result.valid:
        raise HTTPException(status_code=401, detail=result.reason or "owner request rejected")
    return signed_request


app = FastAPI(
    title="OUO Node Owner Management",
    version="0.1.0",
    docs_url=None,
    redoc_url=None,
    openapi_url=None,
)
app.add_middleware(
    RequestBodyLimitMiddleware,
    path_prefixes=("/owner",),
    max_body_bytes=64 * 1024,
    require_federation_headers=False,
)
_pairing_limiter = RateLimiter(
    rate=0.2,
    capacity=10,
    max_buckets=1024,
    idle_ttl_seconds=600,
)


@app.on_event("startup")
def validate_management_runtime() -> None:
    root = Path(ROOT_KEY_PATH)
    state = Path(STATE_PATH)
    if root.resolve() == state.resolve():
        raise RuntimeError("root key and management state paths must differ")
    get_store()


@app.get("/health")
def health():
    return {
        "status": "ok",
        "service": "owner-management",
        "node_id": get_store().node_id,
        "web_panel": False,
    }


@app.post("/owner/v1/pair", status_code=201)
def pair_device(body: PairRequest, request: Request):
    client_host = request.client.host if request.client else "unknown"
    if not _pairing_limiter.allow(client_host):
        raise HTTPException(status_code=429, detail="pairing rate limit exceeded")
    try:
        certificate = get_store().consume_pairing(
            pairing_id=body.pairing_id,
            pairing_secret=body.pairing_secret,
            device_public_key=body.device_public_key,
            now=datetime.now(timezone.utc),
        )
    except ValueError as exc:
        # Do not distinguish unknown IDs from bad secrets over the network.
        raise HTTPException(status_code=401, detail="pairing capability rejected") from exc
    return {"certificate": certificate}


@app.get("/owner/v1/status")
async def owner_status(
    request: Request,
    x_ouo_owner_request: str = Header("", alias="X-OUO-Owner-Request"),
):
    await _authorize(request, x_ouo_owner_request, permission="health.read")
    store = get_store()
    return {
        "status": "ok",
        "node_id": store.node_id,
        "service": "owner-management",
        "web_panel": False,
    }


@app.get("/owner/v1/devices")
async def owner_devices(
    request: Request,
    x_ouo_owner_request: str = Header("", alias="X-OUO-Owner-Request"),
):
    await _authorize(request, x_ouo_owner_request, permission="devices.read")
    return {"devices": get_store().list_devices(now=datetime.now(timezone.utc))}


@app.post("/owner/v1/devices/{serial}/revoke", status_code=200)
async def revoke_owner_device(
    serial: str,
    request: Request,
    x_ouo_owner_request: str = Header("", alias="X-OUO-Owner-Request"),
):
    await _authorize(request, x_ouo_owner_request, permission="devices.revoke")
    if not get_store().revoke_device(serial):
        raise HTTPException(status_code=404, detail="owner device not found")
    return {"status": "revoked", "serial": serial}
