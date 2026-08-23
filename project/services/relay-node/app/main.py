"""Relay Node — real packet forwarding (see spec/0601_RELAY_NODE.md, ADR-0006)."""
import asyncio
import json
import logging
from datetime import datetime, timezone
from functools import lru_cache
from urllib.parse import urlsplit

import httpx
from fastapi import FastAPI, HTTPException, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware

from app.config import settings
from app.fed_security import FederationAuthDep, get_federation_security
from app.node_registration import start_node_registration
from app.ppc_agent import router as ppc_agent_router
from app.challenge import router as challenge_router
from shared.mesh.install import install_mesh
from shared.security.envelope_verify import verify_incoming_federation
from shared.security.health import security_health_snapshot
from shared.security.http_client import federation_post
from shared.security.nonce_cleanup import start_nonce_cleanup
from shared.security.federation_auth import verify_federation_headers
from shared.security.config import HDR_NONCE
from shared.security.config import ENVELOPE_NONCE_TTL_SECONDS
from shared.security.body_limit import FederationBodyLimitMiddleware
from shared.security.relay_challenge_receiver import install_relay_challenge_receiver
from shared.transport.binary_batch import BatchDecodeError, decode_batch, encode_batch
from shared.transport.link_sequence import LinkSequenceStore
from shared.transport.link_cell import validate_link_cell
from shared.transport.mix_pool import MixPoolFull

logger = logging.getLogger(__name__)

app = FastAPI(title="Relay Node", version="0.1.0")

app.add_middleware(
    FederationBodyLimitMiddleware,
    path_prefixes=("/relay/", "/ppc/", "/mix/", "/internal/challenge/"),
)

# ---------------------------------------------------------------------------
# Rate-limiter — скользящее окно (sliding window) по origin_node_id.
# Хранит список timestamp'ов последних запросов для каждого origin.
# Без внешних зависимостей, работает в рамках одного процесса.
# ---------------------------------------------------------------------------
import collections
_rate_window: dict[str, collections.deque] = {}
_quota_window: dict[str, collections.deque] = {}


def _check_rate_limit(origin_node_id: str) -> bool:
    """Возвращает True если лимит НЕ превышен (запрос разрешён)."""
    now = asyncio.get_event_loop().time()
    window_sec = settings.relay_rate_window_seconds
    limit = settings.relay_rate_limit

    if origin_node_id not in _rate_window:
        _rate_window[origin_node_id] = collections.deque()

    dq = _rate_window[origin_node_id]
    # Удаляем устаревшие записи
    cutoff = now - window_sec
    while dq and dq[0] < cutoff:
        dq.popleft()

    if len(dq) >= limit:
        return False  # лимит превышен

    dq.append(now)
    return True


async def _check_certified_traffic_quota(origin_node_id: str, payload: dict) -> bool:
    """Apply certificate budgets over the local relay accounting epoch."""
    quotas = await get_federation_security().trust_cache.capability_quotas(origin_node_id)
    cell_limit = quotas.get("max_cells_per_epoch")
    bandwidth_bps = quotas.get("max_bandwidth_bps")
    if cell_limit is None and bandwidth_bps is None:
        return True
    now = asyncio.get_event_loop().time()
    cutoff = now - settings.relay_rate_window_seconds
    window = _quota_window.setdefault(origin_node_id, collections.deque())
    while window and window[0][0] < cutoff:
        window.popleft()
    encoded_bytes = len(
        json.dumps(payload, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    )
    if cell_limit is not None and (cell_limit <= 0 or len(window) >= cell_limit):
        return False
    if bandwidth_bps is not None:
        byte_budget = bandwidth_bps * settings.relay_rate_window_seconds // 8
        if byte_budget <= 0 or sum(entry[1] for entry in window) + encoded_bytes > byte_budget:
            return False
    window.append((now, encoded_bytes))
    return True

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # MVP only, see home-node/app/main.py for the same note
    allow_methods=["*"],
    allow_headers=["*"],
)

_forwarded_count = 0
_active_ws_connections = 0
_active_ws_by_peer: dict[str, int] = {}
_nonce_cleanup_task: asyncio.Task | None = None


def _reserve_ws_connection() -> bool:
    """Reserve before the first await so concurrent handshakes stay bounded."""
    global _active_ws_connections
    if _active_ws_connections >= settings.ws_max_connections:
        return False
    _active_ws_connections += 1
    return True


def _bind_ws_connection_to_peer(peer_node_id: str, *, certified_limit: int | None = None) -> bool:
    current = _active_ws_by_peer.get(peer_node_id, 0)
    effective_limit = settings.ws_max_connections_per_peer
    if certified_limit is not None:
        effective_limit = min(effective_limit, certified_limit)
    if effective_limit <= 0 or current >= effective_limit:
        return False
    _active_ws_by_peer[peer_node_id] = current + 1
    return True


def _release_ws_connection(peer_node_id: str | None) -> None:
    global _active_ws_connections
    _active_ws_connections = max(0, _active_ws_connections - 1)
    if peer_node_id is None:
        return
    remaining = _active_ws_by_peer.get(peer_node_id, 0) - 1
    if remaining > 0:
        _active_ws_by_peer[peer_node_id] = remaining
    else:
        _active_ws_by_peer.pop(peer_node_id, None)


@lru_cache
def _link_sequence_store() -> LinkSequenceStore:
    return LinkSequenceStore(
        settings.link_sequence_db_path,
        ttl_seconds=settings.link_sequence_ttl_seconds,
        max_records=settings.link_sequence_max_records,
    )

# Maximum relay hops allowed. hop_count=1 means first relay, 2 means second
# (via hub). We never exceed 2 to prevent infinite loops in the mesh.
MAX_HOPS = 2

# /health ping timeout when probing hub candidates.
HUB_PING_TIMEOUT_SECONDS = 3.0


def _normalize_target_url(value) -> str:
    if not isinstance(value, str) or len(value) > 2048:
        raise HTTPException(status_code=400, detail="invalid target_home_node_url")
    parsed = urlsplit(value)
    if parsed.scheme not in ("http", "https") or not parsed.hostname or parsed.username or parsed.password:
        raise HTTPException(status_code=400, detail="invalid target_home_node_url")
    if parsed.query or parsed.fragment:
        raise HTTPException(status_code=400, detail="target_home_node_url must not contain query/fragment")
    return value.rstrip("/")


def _validate_forward_payload(payload: dict) -> tuple[str, int, dict, dict, dict | None]:
    if not isinstance(payload, dict):
        raise HTTPException(status_code=400, detail="forward payload must be an object")
    target_url = _normalize_target_url(payload.get("target_home_node_url"))
    hop_count = payload.get("hop_count", 1)
    if not isinstance(hop_count, int) or isinstance(hop_count, bool) or not 1 <= hop_count <= MAX_HOPS:
        raise HTTPException(
            status_code=400,
            detail=f"hop_count must be an integer between 1 and {MAX_HOPS}",
        )
    envelope = payload.get("envelope")
    conversation_meta = payload.get("conversation_meta")
    federation = payload.get("federation")
    if not isinstance(envelope, dict) or not isinstance(conversation_meta, dict):
        raise HTTPException(status_code=400, detail="envelope and conversation_meta are required objects")
    if federation is not None and not isinstance(federation, dict):
        raise HTTPException(status_code=400, detail="federation must be an object")
    return target_url, hop_count, envelope, conversation_meta, federation


async def _target_is_trusted_home(target_url: str) -> bool:
    from app.mix_service import trusted_home_endpoint

    return await trusted_home_endpoint(target_url)


@app.on_event("startup")
async def on_startup():
    global _nonce_cleanup_task
    start_node_registration()
    _nonce_cleanup_task = start_nonce_cleanup(get_federation_security().nonce_store)
    from app.mix_service import start_mix_runtime
    start_mix_runtime()


@app.on_event("shutdown")
async def on_shutdown():
    global _nonce_cleanup_task
    if _nonce_cleanup_task is not None:
        _nonce_cleanup_task.cancel()
        await asyncio.gather(_nonce_cleanup_task, return_exceptions=True)
        _nonce_cleanup_task = None
    from app.mix_service import stop_mix_runtime
    await stop_mix_runtime()
    from app.node_registration import stop_node_registration
    await stop_node_registration()


@app.get("/health")
def health():
    fs = get_federation_security()
    from app.node_registration import node_registration_status
    return {
        "status": "ok",
        "node_role": "relay",
        "node_id": fs.node_id,
        "node_alias": settings.node_id,
        "load": {
            "forwarded_count": _forwarded_count,
            "active_transport_connections": _active_ws_connections,
            "active_transport_peers": len(_active_ws_by_peer),
        },
        "security": security_health_snapshot(),
        "runtime": {"capabilities": settings.capabilities, "registration": node_registration_status()},
    }


@app.get("/mix/health")
async def mix_health():
    from app.mix_service import mix_status
    return await mix_status()


@app.post("/mix/ingress", status_code=202)
async def mix_ingress(payload: dict, origin_node_id: str = FederationAuthDep):
    fs = get_federation_security()
    if not (
        await fs.trust_cache.has_capability(origin_node_id, "relay")
        or await fs.trust_cache.has_capability(origin_node_id, "home")
    ):
        raise HTTPException(status_code=403, detail="Mix ingress peer capability denied")
    if not _check_rate_limit(origin_node_id):
        raise HTTPException(status_code=429, detail="Mix ingress rate limit exceeded")
    if not await _check_certified_traffic_quota(origin_node_id, payload):
        raise HTTPException(status_code=429, detail="certified Mix traffic quota exceeded")
    from app.mix_service import get_mix_runtime
    try:
        await get_mix_runtime().admit(payload)
    except MixPoolFull as exc:
        raise HTTPException(status_code=429, detail=str(exc))
    except RuntimeError as exc:
        raise HTTPException(status_code=503, detail=str(exc))
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))
    return {"status": "accepted"}


async def _list_hub_urls() -> list[str]:
    """Return quorum-observed, certificate-verified L2+ Relay URLs."""
    from app.mix_service import trusted_relay_endpoints

    return await trusted_relay_endpoints(minimum_level=2)


async def _fastest_hub(hub_urls: list[str]) -> list[str]:
    """Ping all hub candidates and return live ones, fastest-first."""
    if not hub_urls:
        return []

    async def ping(url: str) -> str:
        async with httpx.AsyncClient(timeout=HUB_PING_TIMEOUT_SECONDS) as client:
            r = await client.get(f"{url}/health")
            r.raise_for_status()
            return url

    ranked: list[str] = []
    pending = {asyncio.create_task(ping(u)) for u in hub_urls}
    try:
        while pending:
            done, pending = await asyncio.wait(pending, return_when=asyncio.FIRST_COMPLETED)
            for task in done:
                if task.exception() is None:
                    ranked.append(task.result())
    finally:
        for task in pending:
            task.cancel()
    return ranked


@app.post("/relay/forward")
async def forward(payload: dict, _verified: str = FederationAuthDep):
    """
    Forwards a packet to its destination in up to two relay hops:

      hop 1 (hop_count=1): this relay attempts direct delivery to target home-node.
        On failure, escalates to L2 hub nodes (hop 2).

      hop 2 (hop_count=2): this node IS the hub — deliver directly to target,
        no further relay (MAX_HOPS guard prevents loops).

    Relay never reads/decrypts ciphertext — it only routes opaque envelopes.
    """
    global _forwarded_count

    target_url, hop_count, envelope, conversation_meta, federation = _validate_forward_payload(payload)

    fs = get_federation_security()
    await verify_incoming_federation(
        federation=federation,
        envelope=envelope,
        endpoint="/relay/forward",
        trust_cache=fs.trust_cache,
        nonce_store=fs.nonce_store,
        audit=fs.audit_log,
        expected_origin_node_id=federation.get("origin_node_id") if federation else None,
        conversation_meta=conversation_meta,
        expected_target_node_id=target_url,
        expected_routes={"relay"},
        consume_nonce=False,
    )
    federation_nonce = federation.get("nonce") if federation else None
    if federation_nonce and not fs.nonce_store.consume(
        f"relay-hop:{fs.node_id}:{federation_nonce}",
        federation.get("origin_node_id", ""),
        ENVELOPE_NONCE_TTL_SECONDS,
    ):
        raise HTTPException(status_code=409, detail="Relay hop replay detected")

    if settings.target_validation_mode != "off":
        target_is_trusted = await _target_is_trusted_home(target_url)
        if not target_is_trusted:
            if settings.target_validation_mode == "enforce":
                raise HTTPException(
                    status_code=403,
                    detail="target Home is not present in trusted Discovery catalog",
                )
            logger.warning("Relay target is not verified by Discovery (report mode): %s", target_url)

    origin = federation.get("origin_node_id", settings.node_id) if federation else settings.node_id

    # Rate-limit по origin_node_id (Фаза 3.2)
    if not _check_rate_limit(origin):
        logger.warning(
            "Rate limit exceeded for origin_node_id=%s (%d req/%ds)",
            origin, settings.relay_rate_limit, settings.relay_rate_window_seconds,
        )
        raise HTTPException(
            status_code=429,
            detail=(
                f"Rate limit exceeded: max {settings.relay_rate_limit} requests "
                f"per {settings.relay_rate_window_seconds}s from one node"
            ),
        )

    if not await _check_certified_traffic_quota(origin, payload):
        raise HTTPException(status_code=429, detail="certified Relay traffic quota exceeded")

    deliver_payload = {
        "envelope": envelope,
        "conversation_meta": conversation_meta,
        "origin_node_id": origin,
        "forwarded_by_node_id": fs.node_id,
    }
    if federation is not None:
        deliver_payload["federation"] = federation

    # ── Attempt 1: direct delivery to target home-node ──────────────────────
    async with httpx.AsyncClient(timeout=10.0) as client:
        try:
            resp = await federation_post(
                client,
                f"{target_url}/internal/deliver",
                path="/internal/deliver",
                payload=deliver_payload,
                signing_key=fs.signing_key,
                node_id=fs.node_id,
            )
            resp.raise_for_status()
            _forwarded_count += 1
            return {"status": "forwarded", "route": "relay_direct", "hops": hop_count}
        except httpx.HTTPError as direct_err:
            logger.warning(
                "Relay direct-to-target %s failed (%s); hop_count=%d",
                target_url, direct_err, hop_count,
            )

    # ── Attempt 2: escalate to L2 hub (only if this is hop 1) ───────────────
    # If hop_count >= MAX_HOPS we are already the hub — no further escalation.
    if hop_count >= MAX_HOPS:
        raise HTTPException(
            status_code=502,
            detail=f"Relay forward to {target_url} failed (hub, no further escalation)",
        )

    hub_urls = await _list_hub_urls()
    if not hub_urls:
        raise HTTPException(
            status_code=502,
            detail=f"Direct relay to {target_url} failed and no L2 hubs available",
        )

    live_hubs = await _fastest_hub(hub_urls)
    if not live_hubs:
        raise HTTPException(
            status_code=502,
            detail=f"Direct relay to {target_url} failed and no live L2 hubs responded",
        )

    hub_forward_payload = {
        "envelope": envelope,
        "conversation_meta": conversation_meta,
        "target_home_node_url": target_url,
        "hop_count": hop_count + 1,  # will be 2 — hub won't escalate further
    }
    if federation is not None:
        hub_forward_payload["federation"] = federation

    last_err: Exception | None = None
    async with httpx.AsyncClient(timeout=15.0) as client:
        for hub_url in live_hubs:
            try:
                resp = await federation_post(
                    client,
                    f"{hub_url}/relay/forward",
                    path="/relay/forward",
                    payload=hub_forward_payload,
                    signing_key=fs.signing_key,
                    node_id=fs.node_id,
                )
                resp.raise_for_status()
                _forwarded_count += 1
                logger.info(
                    "Multi-hop: relayed %s → hub %s → target %s",
                    origin, hub_url, target_url,
                )
                return {"status": "forwarded", "route": "relay_hub", "hub": hub_url, "hops": hop_count + 1}
            except httpx.HTTPError as hub_err:
                last_err = hub_err
                logger.warning("Hub %s forward failed (%s), trying next hub", hub_url, hub_err)

    raise HTTPException(
        status_code=502,
        detail=f"Direct relay to {target_url} failed and all {len(live_hubs)} hub(s) failed",
    )


@app.websocket("/relay/ws")
async def relay_websocket(websocket: WebSocket):
    """Persistent authenticated binary-batch adapter for Basic Relay."""
    if not _reserve_ws_connection():
        await websocket.close(code=4429, reason="connection limit reached")
        return
    peer_node_id = None
    peer_slot_reserved = False
    try:
        fs = get_federation_security()
        try:
            peer_node_id = await verify_federation_headers(
                websocket.headers,
                method="GET",
                path="/relay/ws",
                body=b"",
                trust_cache=fs.trust_cache,
                nonce_store=fs.nonce_store,
            )
            if not (
                await fs.trust_cache.has_capability(peer_node_id, "home")
                or await fs.trust_cache.has_capability(peer_node_id, "relay")
            ):
                raise HTTPException(status_code=403, detail="peer capability is not allowed")
            connection_id = websocket.headers.get(HDR_NONCE)
            if not connection_id:
                raise HTTPException(status_code=401, detail="signed connection nonce is required")
        except HTTPException as exc:
            await websocket.close(
                code=4400 + min(exc.status_code, 99), reason="authentication failed"
            )
            return

        quotas = await fs.trust_cache.capability_quotas(peer_node_id)
        certified_connection_limit = quotas.get("max_connections")
        if not _bind_ws_connection_to_peer(
            peer_node_id, certified_limit=certified_connection_limit
        ):
            await websocket.close(code=4429, reason="per-peer connection limit reached")
            return
        peer_slot_reserved = True
        await websocket.accept()
        while True:
            try:
                message = await asyncio.wait_for(
                    websocket.receive(), timeout=settings.ws_idle_timeout_seconds
                )
            except asyncio.TimeoutError:
                await websocket.close(code=4408, reason="idle timeout")
                break
            if message.get("type") == "websocket.disconnect":
                break
            raw = message.get("bytes")
            if raw is None:
                await websocket.close(code=4400, reason="binary batches required")
                break
            try:
                batch = decode_batch(raw)
            except BatchDecodeError:
                await websocket.close(code=4400, reason="invalid binary batch")
                break
            if len(batch.cells) > settings.ws_max_cells_per_batch:
                await websocket.close(code=4408, reason="batch cell quota exceeded")
                break
            if not _link_sequence_store().accept(
                peer_node_id=peer_node_id,
                connection_id=connection_id,
                sequence=batch.sequence,
            ):
                await websocket.close(code=4403, reason="batch replay or reorder")
                break

            result_cells = []
            for cell in batch.cells:
                try:
                    payload = json.loads(cell)
                    validation_error = validate_link_cell(
                        payload, now=datetime.now(timezone.utc)
                    )
                    if validation_error:
                        raise ValueError(validation_error)
                    cell_id = payload["cell_id"]
                    if not fs.nonce_store.consume(
                        f"link-cell:{cell_id}", peer_node_id, settings.link_sequence_ttl_seconds
                    ):
                        raise HTTPException(status_code=403, detail="link cell replay")
                    payload = dict(payload["payload"])
                    result = await asyncio.wait_for(
                        forward(payload, _verified=peer_node_id),
                        timeout=settings.ws_cell_timeout_seconds,
                    )
                    response = {"ok": True, "result": result}
                except asyncio.TimeoutError:
                    response = {
                        "ok": False,
                        "status": 504,
                        "detail": "relay cell processing timeout",
                    }
                except (json.JSONDecodeError, UnicodeDecodeError, ValueError) as exc:
                    response = {"ok": False, "status": 400, "detail": str(exc)}
                except HTTPException as exc:
                    response = {"ok": False, "status": exc.status_code, "detail": exc.detail}
                except Exception:
                    logger.exception("Unhandled Relay WebSocket cell error")
                    response = {"ok": False, "status": 500, "detail": "internal error"}
                result_cells.append(
                    json.dumps(response, separators=(",", ":")).encode("utf-8")
                )
            try:
                await asyncio.wait_for(
                    websocket.send_bytes(
                        encode_batch(sequence=batch.sequence, cells=result_cells)
                    ),
                    timeout=settings.ws_send_timeout_seconds,
                )
            except asyncio.TimeoutError:
                await websocket.close(code=4408, reason="send timeout")
                break
    except WebSocketDisconnect:
        pass
    finally:
        _release_ws_connection(peer_node_id if peer_slot_reserved else None)


app.include_router(ppc_agent_router)
app.include_router(challenge_router)
install_relay_challenge_receiver(app, get_federation_security)


install_mesh(
    app,
    discovery_url=settings.discovery_url,
    node_id=settings.node_id,
    cluster_id=settings.cluster_id,
)
