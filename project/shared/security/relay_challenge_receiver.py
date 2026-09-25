"""Stateless receiver used to prove that a Relay reached another OUO node."""

from __future__ import annotations

import base64
import hashlib
import secrets
from datetime import datetime, timedelta, timezone
from typing import Callable

from fastapi import FastAPI, HTTPException, Request

from shared.security.federation_auth import verify_federation_request
from shared.security.relay_challenge_receipt import issue_relay_challenge_receipt
from shared.security.runtime import FederationSecurity


def _decode_cell(value: object) -> bytes:
    if not isinstance(value, str) or len(value) != 5464:
        raise HTTPException(status_code=400, detail="invalid challenge cell")
    try:
        cell = base64.b64decode(value, altchars=b"-_", validate=True)
    except (ValueError, TypeError) as exc:
        raise HTTPException(status_code=400, detail="invalid challenge cell") from exc
    if len(cell) != 4096:
        raise HTTPException(status_code=400, detail="invalid challenge cell")
    return cell


def install_relay_challenge_receiver(
    app: FastAPI, security_factory: Callable[[], FederationSecurity]
) -> None:
    @app.post("/internal/challenge/relay/receive")
    async def receive_relay_challenge(request: Request):
        fs = security_factory()
        origin = await verify_federation_request(
            request,
            trust_cache=fs.trust_cache,
            nonce_store=fs.nonce_store,
            path=request.url.path,
        )
        if not await fs.trust_cache.has_capability(origin, "relay"):
            raise HTTPException(status_code=403, detail="Relay capability required")
        try:
            payload = await request.json()
        except ValueError as exc:
            raise HTTPException(status_code=400, detail="invalid JSON") from exc
        required = {"challenge_id", "destination_node_id", "cell_b64", "expected_hash", "expires_at"}
        if not isinstance(payload, dict) or set(payload) != required:
            raise HTTPException(status_code=400, detail="invalid Relay challenge payload")
        own_node_id = fs.identity_node_id
        if not own_node_id or payload.get("destination_node_id") != own_node_id:
            raise HTTPException(status_code=409, detail="Relay challenge destination mismatch")
        challenge_id = payload.get("challenge_id")
        digest = payload.get("expected_hash")
        if not isinstance(challenge_id, str) or not 1 <= len(challenge_id) <= 128:
            raise HTTPException(status_code=400, detail="invalid challenge_id")
        if not isinstance(digest, str) or len(digest) != 64 or any(c not in "0123456789abcdef" for c in digest):
            raise HTTPException(status_code=400, detail="invalid expected_hash")
        cell = _decode_cell(payload.get("cell_b64"))
        if not secrets.compare_digest(hashlib.sha256(cell).hexdigest(), digest):
            raise HTTPException(status_code=400, detail="challenge cell hash mismatch")
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
        return {
            "receipt": issue_relay_challenge_receipt(
                challenge_id=challenge_id,
                receiver_node_id=own_node_id,
                cell_hash=digest,
                signing_key=fs.signing_key,
                received_at=now,
                expires_at=expires_at,
            )
        }
