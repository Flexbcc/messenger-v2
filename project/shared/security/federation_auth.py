import uuid
from datetime import datetime, timezone
from typing import Callable, Optional

from fastapi import HTTPException, Request

from shared.security.canonical import signing_payload
from shared.security.config import (
    FEDERATION_TIMESTAMP_SKEW_SECONDS,
    HDR_NODE_ID,
    HDR_NONCE,
    HDR_SIGNATURE,
    HDR_TIMESTAMP,
    INTERNAL_SECURITY_MODE,
    NONCE_TTL_SECONDS,
)
from shared.security.keys import SigningKey, sign_message, verify_message
from shared.security.metrics import RateLimiter, metrics
from shared.security.nonce_store import NonceStore
from shared.security.policy import allowed_capabilities
from shared.security.trust_cache import TrustCache

_rate_limiter = RateLimiter()


def _parse_timestamp(ts: str) -> datetime:
    if ts.endswith("Z"):
        ts = ts[:-1] + "+00:00"
    return datetime.fromisoformat(ts)


def _mode_legacy() -> bool:
    return INTERNAL_SECURITY_MODE in ("legacy", "off", "")


async def verify_federation_request(
    request: Request,
    *,
    trust_cache: TrustCache,
    nonce_store: NonceStore,
    path: Optional[str] = None,
) -> str:
    """
    Verify federation headers. Returns origin node_id.
    In legacy mode returns header node_id or 'legacy'.
    """
    if _mode_legacy():
        return request.headers.get(HDR_NODE_ID, "legacy")

    node_id = request.headers.get(HDR_NODE_ID)
    timestamp = request.headers.get(HDR_TIMESTAMP)
    nonce = request.headers.get(HDR_NONCE)
    signature = request.headers.get(HDR_SIGNATURE)

    if not all([node_id, timestamp, nonce, signature]):
        raise HTTPException(status_code=401, detail="Missing federation auth headers")

    if not _rate_limiter.allow(node_id):
        metrics().rate_limit_hits += 1
        raise HTTPException(status_code=429, detail="Rate limit exceeded")

    try:
        ts = _parse_timestamp(timestamp)
    except ValueError as exc:
        raise HTTPException(status_code=401, detail="Invalid timestamp") from exc

    now = datetime.now(timezone.utc)
    skew = abs((now - ts).total_seconds())
    if skew > FEDERATION_TIMESTAMP_SKEW_SECONDS:
        metrics().timestamp_rejected += 1
        raise HTTPException(status_code=401, detail="Timestamp outside allowed window")

    if not await trust_cache.is_trusted(node_id):
        metrics().untrusted_node += 1
        raise HTTPException(status_code=403, detail="Untrusted origin node")

    allowed = allowed_capabilities(request.method, path or request.url.path)
    if allowed:
        ok_cap = False
        for cap in allowed:
            if await trust_cache.has_capability(node_id, cap):
                ok_cap = True
                break
        if not ok_cap:
            metrics().capability_denied += 1
            raise HTTPException(status_code=403, detail="Capability not allowed for this endpoint")

    body = await request.body()
    sign_path = path or request.url.path
    message = signing_payload(
        node_id=node_id,
        timestamp=timestamp,
        nonce=nonce,
        method=request.method,
        path=sign_path,
        body=body,
    )

    pub = await trust_cache.signing_public_key(node_id)
    if not pub:
        metrics().untrusted_node += 1
        raise HTTPException(status_code=403, detail="Origin node has no signing_public_key")

    if not verify_message(pub, message, signature):
        metrics().invalid_signature += 1
        raise HTTPException(status_code=401, detail="Invalid federation signature")

    if not nonce_store.consume(nonce, node_id, NONCE_TTL_SECONDS):
        metrics().replay_rejected += 1
        raise HTTPException(status_code=403, detail="Replay detected (nonce reused)")

    return node_id


def sign_federation_request(
    *,
    signing_key: SigningKey,
    node_id: str,
    method: str,
    path: str,
    body: bytes,
) -> dict[str, str]:
    timestamp = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
    nonce = str(uuid.uuid4())
    message = signing_payload(
        node_id=node_id,
        timestamp=timestamp,
        nonce=nonce,
        method=method,
        path=path,
        body=body,
    )
    signature = sign_message(signing_key, message)
    return {
        HDR_NODE_ID: node_id,
        HDR_TIMESTAMP: timestamp,
        HDR_NONCE: nonce,
        HDR_SIGNATURE: signature,
    }


def federation_auth_dependency(
    trust_cache: TrustCache,
    nonce_store: NonceStore,
    path: Optional[str] = None,
) -> Callable:
    async def _dep(request: Request) -> str:
        return await verify_federation_request(
            request, trust_cache=trust_cache, nonce_store=nonce_store, path=path
        )

    return _dep
