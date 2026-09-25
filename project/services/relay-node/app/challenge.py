"""Synthetic Relay delivery adapter: observer -> Relay -> independent node."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
import os
from urllib.parse import urlsplit, urlunsplit

import httpx
from shared.security.outbound_tls import outbound_tls_verify
from fastapi import APIRouter, HTTPException, Request

from app.fed_security import ChallengeObserverAuthDep, get_federation_security
from shared.security.http_client import federation_post


router = APIRouter(prefix="/internal/challenge/relay", tags=["challenge"])


def _endpoint(value: object) -> str:
    if not isinstance(value, str):
        raise HTTPException(status_code=503, detail="destination endpoint unavailable")
    parsed = urlsplit(value)
    allowed_schemes = {"https", "wss"}
    if os.environ.get("NODE_CHALLENGE_ALLOW_HTTP", "false").lower() in {
        "1", "true", "yes", "on"
    }:
        allowed_schemes.add("http")
    if parsed.scheme not in allowed_schemes or not parsed.hostname or parsed.username or parsed.password:
        raise HTTPException(status_code=503, detail="destination endpoint unavailable")
    path = parsed.path.rstrip("/")
    for suffix in ("/relay/ws", "/mix/ingress"):
        if path.endswith(suffix):
            path = path[: -len(suffix)]
    scheme = "http" if parsed.scheme == "http" else "https"
    return urlunsplit((scheme, parsed.netloc, path, "", "")).rstrip("/")


@router.post("/deliver")
async def deliver(request: Request, _observer: str = ChallengeObserverAuthDep):
    try:
        payload = await request.json()
    except ValueError as exc:
        raise HTTPException(status_code=400, detail="invalid JSON") from exc
    required = {"challenge_id", "destination_node_id", "cell_b64", "expected_hash", "expires_at"}
    if not isinstance(payload, dict) or set(payload) != required:
        raise HTTPException(status_code=400, detail="invalid Relay challenge payload")
    destination_node_id = payload.get("destination_node_id")
    if not isinstance(destination_node_id, str) or not 1 <= len(destination_node_id) <= 256:
        raise HTTPException(status_code=400, detail="invalid destination NodeID")
    fs = get_federation_security()
    destination = await fs.trust_cache.get_node(destination_node_id)
    if destination is None:
        raise HTTPException(status_code=503, detail="destination is not quorum-trusted")
    try:
        value = payload.get("expires_at")
        expires_at = datetime.fromisoformat(value[:-1] + "+00:00" if isinstance(value, str) and value.endswith("Z") else value)
        if expires_at.tzinfo is None or expires_at.utcoffset() is None:
            raise ValueError
        expires_at = expires_at.astimezone(timezone.utc)
    except (TypeError, ValueError):
        raise HTTPException(status_code=400, detail="invalid challenge expiry")
    now = datetime.now(timezone.utc)
    if not now < expires_at <= now + timedelta(minutes=5):
        raise HTTPException(status_code=400, detail="challenge expiry outside allowed window")
    base = _endpoint(destination.get("node_url"))
    path = "/internal/challenge/relay/receive"
    try:
        async with httpx.AsyncClient(timeout=5.0, follow_redirects=False, trust_env=False, verify=outbound_tls_verify()) as client:
            response = await federation_post(
                client,
                f"{base}{path}",
                path=path,
                payload=payload,
                signing_key=fs.signing_key,
                node_id=fs.node_id,
            )
            response.raise_for_status()
            result = response.json()
    except (httpx.HTTPError, ValueError) as exc:
        raise HTTPException(status_code=502, detail="Relay challenge forwarding failed") from exc
    receipt = result.get("receipt") if isinstance(result, dict) else None
    if not isinstance(receipt, dict):
        raise HTTPException(status_code=502, detail="destination receipt missing")
    return {"receipt": receipt}
