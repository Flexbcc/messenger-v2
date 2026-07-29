"""Relay Node — real packet forwarding (see spec/0601_RELAY_NODE.md, ADR-0006)."""
import asyncio
import logging

import httpx
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware

from app.config import settings
from app.fed_security import FederationAuthDep, get_federation_security
from app.node_registration import start_node_registration
from app.ppc_agent import router as ppc_agent_router
from shared.mesh.install import install_mesh
from shared.security.envelope_verify import verify_incoming_federation
from shared.security.health import security_health_snapshot
from shared.security.http_client import federation_post
from shared.security.nonce_cleanup import start_nonce_cleanup

logger = logging.getLogger(__name__)

app = FastAPI(title="Relay Node", version="0.1.0")

# ---------------------------------------------------------------------------
# Rate-limiter — скользящее окно (sliding window) по origin_node_id.
# Хранит список timestamp'ов последних запросов для каждого origin.
# Без внешних зависимостей, работает в рамках одного процесса.
# ---------------------------------------------------------------------------
import collections
_rate_window: dict[str, collections.deque] = {}


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

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # MVP only, see home-node/app/main.py for the same note
    allow_methods=["*"],
    allow_headers=["*"],
)

_forwarded_count = 0

# Maximum relay hops allowed. hop_count=1 means first relay, 2 means second
# (via hub). We never exceed 2 to prevent infinite loops in the mesh.
MAX_HOPS = 2

# /health ping timeout when probing hub candidates.
HUB_PING_TIMEOUT_SECONDS = 3.0


@app.on_event("startup")
async def on_startup():
    start_node_registration()
    start_nonce_cleanup(get_federation_security().nonce_store)


@app.get("/health")
def health():
    return {
        "status": "ok",
        "node_role": "relay",
        "node_id": settings.node_id,
        "load": {"forwarded_count": _forwarded_count},
        "security": security_health_snapshot(),
    }


async def _list_hub_urls() -> list[str]:
    """Return URLs of L2-hub nodes (trust_level >= 2) from Discovery, excluding self."""
    try:
        async with httpx.AsyncClient(timeout=5.0) as client:
            resp = await client.get(
                f"{settings.discovery_url}/registry/nodes",
                params={"capability": "relay"},
            )
            resp.raise_for_status()
        return [
            node["node_url"]
            for node in resp.json().get("nodes", [])
            if node.get("status") == "online"
            and node.get("trust_status") == "trusted"
            and (node.get("trust_level") or 0) >= 2
            and node["node_url"].rstrip("/") != settings.public_url.rstrip("/")
        ]
    except Exception as exc:
        logger.warning("Failed to fetch hub list from Discovery: %s", exc)
        return []


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

    target_url = payload.get("target_home_node_url")
    if not target_url:
        raise HTTPException(status_code=400, detail="target_home_node_url is required")

    hop_count: int = int(payload.get("hop_count", 1))
    if hop_count > MAX_HOPS:
        raise HTTPException(
            status_code=400,
            detail=f"hop_count={hop_count} exceeds MAX_HOPS={MAX_HOPS} — loop prevention"
        )

    envelope = payload["envelope"]
    conversation_meta = payload["conversation_meta"]
    federation = payload.get("federation")

    fs = get_federation_security()
    await verify_incoming_federation(
        federation=federation,
        envelope=envelope,
        endpoint="/relay/forward",
        trust_cache=fs.trust_cache,
        nonce_store=fs.nonce_store,
        audit=fs.audit_log,
        expected_origin_node_id=federation.get("origin_node_id") if federation else None,
        consume_nonce=False,
    )

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

    deliver_payload = {
        "envelope": envelope,
        "conversation_meta": conversation_meta,
        "origin_node_id": origin,
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


app.include_router(ppc_agent_router)


install_mesh(
    app,
    discovery_url=settings.discovery_url,
    node_id=settings.node_id,
    cluster_id=settings.cluster_id,
)
