import uuid
from datetime import datetime, timezone
from typing import Callable, Mapping, Optional

from fastapi import HTTPException, Request

from shared.security.canonical import signing_payload
from shared.security.config import (
    FEDERATION_MAX_BODY_BYTES,
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

_admission_rate_limiter = RateLimiter(
    rate=200.0, capacity=400.0, max_buckets=1, idle_ttl_seconds=600.0
)
_rate_limiter = RateLimiter()


def _parse_timestamp(ts: str) -> datetime:
    if ts.endswith("Z"):
        ts = ts[:-1] + "+00:00"
    parsed = datetime.fromisoformat(ts)
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        raise ValueError("timestamp must include timezone")
    return parsed.astimezone(timezone.utc)


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

    Legacy mode: подпись не требуется, но origin_node_id обязан быть
    зарегистрирован в Discovery (trust_status=trusted). Это закрывает
    анонимный инжект от случайных хостов в LAN без ломки совместимости.
    Signed mode: полная проверка подписи + nonce + capability.
    """
    effective_path = path or request.url.path
    if _mode_legacy():
        return await verify_federation_headers(
            request.headers,
            method=request.method,
            path=effective_path,
            body=b"",
            trust_cache=trust_cache,
            nonce_store=nonce_store,
        )

    context = _validate_signed_admission_headers(request.headers)
    _reject_oversized_declared_body(request.headers)
    public_key = await _authorize_signed_peer(
        context,
        method=request.method,
        path=effective_path,
        trust_cache=trust_cache,
    )
    body = await _read_bounded_body(request)
    _verify_signature_and_consume_nonce(
        context,
        method=request.method,
        path=effective_path,
        body=body,
        public_key=public_key,
        nonce_store=nonce_store,
    )
    return context["node_id"]


def _validate_signed_admission_headers(headers: Mapping[str, str]) -> dict[str, str]:
    node_id = headers.get(HDR_NODE_ID)
    timestamp = headers.get(HDR_TIMESTAMP)
    nonce = headers.get(HDR_NONCE)
    signature = headers.get(HDR_SIGNATURE)

    if not all([node_id, timestamp, nonce, signature]):
        metrics().admission_rejected += 1
        raise HTTPException(status_code=401, detail="Missing federation auth headers")
    if (
        not isinstance(node_id, str)
        or not 1 <= len(node_id) <= 256
        or not isinstance(timestamp, str)
        or len(timestamp) > 64
        or not isinstance(nonce, str)
        or len(nonce) != 36
        or not isinstance(signature, str)
        or len(signature) != 88
    ):
        metrics().admission_rejected += 1
        raise HTTPException(status_code=401, detail="Malformed federation auth headers")
    try:
        if str(uuid.UUID(nonce)) != nonce:
            raise ValueError("non-canonical nonce")
    except ValueError as exc:
        metrics().admission_rejected += 1
        raise HTTPException(status_code=401, detail="Invalid federation nonce") from exc
    if not _admission_rate_limiter.allow("anonymous"):
        metrics().rate_limit_hits += 1
        raise HTTPException(status_code=429, detail="Admission rate limit exceeded")
    try:
        parsed_timestamp = _parse_timestamp(timestamp)
    except ValueError as exc:
        metrics().admission_rejected += 1
        raise HTTPException(status_code=401, detail="Invalid timestamp") from exc
    now = datetime.now(timezone.utc)
    if abs((now - parsed_timestamp).total_seconds()) > FEDERATION_TIMESTAMP_SKEW_SECONDS:
        metrics().timestamp_rejected += 1
        raise HTTPException(status_code=401, detail="Timestamp outside allowed window")
    return {
        "node_id": node_id,
        "timestamp": timestamp,
        "nonce": nonce,
        "signature": signature,
    }


def _reject_oversized_declared_body(headers: Mapping[str, str]) -> None:
    value = headers.get("content-length")
    if value is None:
        return
    try:
        length = int(value)
    except (TypeError, ValueError) as exc:
        metrics().admission_rejected += 1
        raise HTTPException(status_code=400, detail="Invalid Content-Length") from exc
    if length < 0:
        metrics().admission_rejected += 1
        raise HTTPException(status_code=400, detail="Invalid Content-Length")
    if length > FEDERATION_MAX_BODY_BYTES:
        metrics().admission_rejected += 1
        raise HTTPException(status_code=413, detail="Federation request body exceeds limit")


async def _read_bounded_body(request: Request) -> bytes:
    cached = getattr(request, "_body", None)
    if isinstance(cached, bytes):
        if len(cached) > FEDERATION_MAX_BODY_BYTES:
            metrics().admission_rejected += 1
            raise HTTPException(status_code=413, detail="Federation request body exceeds limit")
        return cached
    # Unit-test doubles and compatible request adapters may expose only body().
    # Real Starlette requests always take the bounded streaming path below.
    if not isinstance(request, Request):
        body = await request.body()
        if not isinstance(body, bytes) or len(body) > FEDERATION_MAX_BODY_BYTES:
            metrics().admission_rejected += 1
            raise HTTPException(status_code=413, detail="Federation request body exceeds limit")
        return body
    chunks: list[bytes] = []
    total = 0
    async for chunk in request.stream():
        total += len(chunk)
        if total > FEDERATION_MAX_BODY_BYTES:
            metrics().admission_rejected += 1
            raise HTTPException(status_code=413, detail="Federation request body exceeds limit")
        chunks.append(chunk)
    body = b"".join(chunks)
    request._body = body
    return body


async def _authorize_signed_peer(
    context: Mapping[str, str],
    *,
    method: str,
    path: str,
    trust_cache: TrustCache,
) -> str:
    node_id = context["node_id"]
    if not await trust_cache.is_trusted(node_id):
        metrics().untrusted_node += 1
        raise HTTPException(status_code=403, detail="Untrusted origin node")
    if not _rate_limiter.allow(node_id):
        metrics().rate_limit_hits += 1
        raise HTTPException(status_code=429, detail="Rate limit exceeded")
    allowed = allowed_capabilities(method, path)
    if allowed and not any(
        [await trust_cache.has_capability(node_id, capability) for capability in allowed]
    ):
        metrics().capability_denied += 1
        raise HTTPException(status_code=403, detail="Capability not allowed for this endpoint")
    public_key = await trust_cache.signing_public_key(node_id)
    if not public_key:
        metrics().untrusted_node += 1
        raise HTTPException(status_code=403, detail="Origin node has no signing_public_key")
    return public_key


def _verify_signature_and_consume_nonce(
    context: Mapping[str, str],
    *,
    method: str,
    path: str,
    body: bytes,
    public_key: str,
    nonce_store: NonceStore,
) -> None:
    message = signing_payload(
        node_id=context["node_id"],
        timestamp=context["timestamp"],
        nonce=context["nonce"],
        method=method,
        path=path,
        body=body,
    )
    if not verify_message(public_key, message, context["signature"]):
        metrics().invalid_signature += 1
        raise HTTPException(status_code=401, detail="Invalid federation signature")
    if not nonce_store.consume(context["nonce"], context["node_id"], NONCE_TTL_SECONDS):
        metrics().replay_rejected += 1
        raise HTTPException(status_code=403, detail="Replay detected (nonce reused)")


async def verify_federation_headers(
    headers: Mapping[str, str],
    *,
    method: str,
    path: str,
    body: bytes,
    trust_cache: TrustCache,
    nonce_store: NonceStore,
) -> str:
    """Verify federation auth without requiring an HTTP Request body reader."""
    if _mode_legacy():
        node_id = headers.get(HDR_NODE_ID)
        if not node_id:
            raise HTTPException(
                status_code=401,
                detail=f"Missing {HDR_NODE_ID} header (legacy federation mode requires node_id)"
            )
        if not await trust_cache.is_trusted(node_id):
            metrics().untrusted_node += 1
            raise HTTPException(
                status_code=403,
                detail=f"Unknown or untrusted origin node '{node_id}' (not registered in Discovery)"
            )
        return node_id

    context = _validate_signed_admission_headers(headers)
    public_key = await _authorize_signed_peer(
        context,
        method=method,
        path=path,
        trust_cache=trust_cache,
    )
    _verify_signature_and_consume_nonce(
        context,
        method=method,
        path=path,
        body=body,
        public_key=public_key,
        nonce_store=nonce_store,
    )
    return context["node_id"]


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
