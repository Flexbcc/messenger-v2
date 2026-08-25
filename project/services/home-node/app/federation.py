"""
Federation client — adapted from the RoutingService/forward_to_peer pattern
in ~/secure-messenger-project/backend/app/services/routing.py (ADR-0005),
but resolving addresses via a dedicated Discovery Node instead of
broadcasting to every configured peer.
"""
from __future__ import annotations

import asyncio
import hashlib
import json
import logging
import time
from typing import Awaitable, Callable, Optional

import httpx

from app.config import settings
from app.fed_security import get_federation_security
from shared.security.http_client import federation_delete, federation_get, federation_post
from shared.security.record_verifier import verify_user_record_response
from shared.security.sealed_sender import seal_sender
from shared.transport.relay_adapter import RelayTransportAdapter
from shared.transport.ws_relay_client import RelayTransportError
from shared.security.payload_builder import (
    build_buffer_payload,
    build_deliver_payload,
    build_delivery_ack_payload,
    build_home_changed_payload,
    build_relay_forward_payload,
)

logger = logging.getLogger(__name__)

RELAY_PING_TIMEOUT_SECONDS = 3.0

# ---------------------------------------------------------------------------
# Federation delivery counters — сбрасываются при рестарте процесса.
# Отдаются в /health → load.federation для admin UI.
# ---------------------------------------------------------------------------
_fed_counters: dict[str, int] = {
    "direct_ok": 0,       # успешная прямая доставка
    "relay_ok": 0,        # успешная доставка через relay/hub
    "buffer_ok": 0,       # сообщение ушло в Storage Node buffer
    "failed": 0,          # все пути отказали (сообщение потеряно или в outbox)
}


def get_federation_counters() -> dict[str, int]:
    return dict(_fed_counters)


# Post-R5 user->home resolve cache (docs/reality/R4-routing.md Gaps "Нет
# TTL/кэша user→home"). Plain dict keyed by user_id -> (home_node_url,
# expires_at monotonic seconds). Safe without locks under single-process
# asyncio: lookups/writes are synchronous with no `await` in between, so
# there's no interleaving point for a race.
_home_node_cache: dict[str, tuple[str, float]] = {}
_home_node_stale_cache: dict[str, tuple[str, float]] = {}
_relay_transport: RelayTransportAdapter | None = None


def _get_relay_transport() -> RelayTransportAdapter:
    global _relay_transport
    if _relay_transport is None:
        fs = get_federation_security()
        _relay_transport = RelayTransportAdapter(
            signing_key=fs.signing_key,
            node_id=fs.node_id,
            mode=settings.relay_transport_mode,
            timeout_seconds=10.0,
            quic_ca_file=settings.relay_quic_ca_file or None,
        )
    return _relay_transport


async def close_relay_transport() -> None:
    global _relay_transport
    client = _relay_transport
    _relay_transport = None
    if client is not None:
        await client.close()


def _cache_lookup(cache: dict[str, tuple[str, float]], user_id: str, now: float) -> Optional[str]:
    entry = cache.get(user_id)
    if entry is None:
        return None
    home_node_url, expires_at = entry
    if now >= expires_at:
        return None
    return home_node_url


def _cache_store(
    cache: dict[str, tuple[str, float]],
    user_id: str,
    home_node_url: str,
    now: float,
    ttl_seconds: float,
) -> None:
    if ttl_seconds <= 0:
        return
    cache[user_id] = (home_node_url, now + ttl_seconds)


async def publish_user_to_discovery(
    user_id: str,
    display_name: str,
    auth_public_key: str,
    login: str | None = None,
    username_search_enabled: bool = True,
) -> Optional[dict]:
    """Returns home-change info ({"user_id", "home_node_url", "home_updated_at"})
    if this publish just moved user_id's home to this node, else None — the
    caller (app.discovery_publish) uses it to trigger the CONTROL notify to
    contacts (app.fanout.notify_contacts_of_home_change)."""
    async with httpx.AsyncClient(timeout=5.0) as client:
        try:
            body = {
                "user_id": user_id,
                "home_node_url": settings.public_url,
                "display_name": display_name,
                "auth_public_key": auth_public_key,
                "cluster_id": settings.cluster_id,
                "username_search_enabled": username_search_enabled,
            }
            if login:
                body["login"] = login
            resp = await client.post(
                f"{settings.discovery_url}/registry/users",
                json=body,
            )
            return _home_change_info(user_id, resp)
        except httpx.HTTPError as e:
            logger.warning("Failed to publish user %s to discovery: %s", user_id, e)
            return None


def _home_change_info(user_id: str, resp: httpx.Response) -> Optional[dict]:
    """Discovery response enrichment (Post-R5): if home_node_url just moved
    to this node, log it and return the info needed to notify contacts
    (see R4-routing.md Gaps / 0203_ROUTING.md "Смена Home")."""
    if resp.status_code != 200:
        return None
    try:
        data = resp.json()
    except ValueError:
        return None
    previous = data.get("previous_home_node_url")
    if previous and previous != settings.public_url:
        logger.info(
            "Home changed for user %s: %s -> %s (this node). Notifying "
            "contacts in this user's direct/group conversations (best-effort).",
            user_id,
            previous,
            settings.public_url,
        )
        return {
            "user_id": user_id,
            "home_node_url": settings.public_url,
            "home_updated_at": data.get("home_updated_at"),
        }
    return None


async def notify_remote_home_changed(
    target_home_node_url: str,
    *,
    user_id: str,
    new_home_node_url: str,
    home_updated_at: Optional[str],
) -> None:
    """Post-R5 CONTROL notify (docs/reality/R4-routing.md Gaps "Нет notify
    смены Home"): tells a peer Home that user_id's home moved, carrying no
    chat ciphertext — just enough for it to push its own connected clients
    (WS `home_changed`) and let their next send benefit from a fresh
    resolve. Single direct attempt only: unlike deliver_to_remote_home_node,
    losing this is not data loss, so no relay fallback / outbox retry."""
    fs = get_federation_security()
    payload = build_home_changed_payload(
        signing_key=fs.signing_key,
        origin_node_id=fs.node_id,
        user_id=user_id,
        new_home_node_url=new_home_node_url,
        home_updated_at=home_updated_at,
        target_node_id=target_home_node_url,
    )
    async with httpx.AsyncClient(timeout=5.0) as client:
        resp = await federation_post(
            client,
            f"{target_home_node_url}/internal/home-changed",
            path="/internal/home-changed",
            payload=payload,
            signing_key=fs.signing_key,
            node_id=fs.node_id,
        )
        resp.raise_for_status()


async def notify_remote_delivery_ack(
    target_home_node_url: str,
    *,
    packet_id: str,
    conversation_id: str,
    from_user_id: str,
    acked_at: str,
) -> None:
    """Post-R5 e2e delivery ACK (spec/0202_DELIVERY.md): tells the sender's
    Home Node that from_user_id ack'd packet_id, so it can push WS
    `delivery_ack` to its own locally-connected sender. Single direct
    attempt only, like notify_remote_home_changed — losing this only delays
    the sender's delivery receipt, the recipient's ack has already been
    persisted and 200'd."""
    fs = get_federation_security()
    payload = build_delivery_ack_payload(
        signing_key=fs.signing_key,
        origin_node_id=fs.node_id,
        packet_id=packet_id,
        conversation_id=conversation_id,
        from_user_id=from_user_id,
        acked_at=acked_at,
        target_node_id=target_home_node_url,
    )
    async with httpx.AsyncClient(timeout=5.0) as client:
        resp = await federation_post(
            client,
            f"{target_home_node_url}/internal/delivery-ack",
            path="/internal/delivery-ack",
            payload=payload,
            signing_key=fs.signing_key,
            node_id=fs.node_id,
        )
        resp.raise_for_status()


async def resolve_home_node(user_id: str, *, force_refresh: bool = False) -> Optional[str]:
    """Returns the Home Node public URL hosting user_id, or None if unknown.

    Post-R5: served from a short in-memory TTL cache when possible, to avoid
    a live Discovery GET on every remote deliver (DISCOVERY_RESOLVE_CACHE_TTL_SECONDS,
    default 60s; 0 disables). Pass force_refresh=True to bypass the cache and
    always hit Discovery live — used by the outbox retry path, which needs a
    fresh answer to detect a moved home_node_url; a fresh result still
    refreshes the cache for other callers (e.g. fan_out).
    """
    now = time.monotonic()
    if not force_refresh:
        cached = _cache_lookup(_home_node_cache, user_id, now)
        if cached is not None:
            return cached

    async with httpx.AsyncClient(timeout=5.0) as client:
        try:
            resp = await client.get(f"{settings.discovery_url}/registry/users/{user_id}")
        except httpx.HTTPError as e:
            logger.warning("Discovery lookup failed for %s: %s", user_id, e)
            stale = _cache_lookup(_home_node_stale_cache, user_id, now)
            if stale is not None:
                logger.warning("Using last-known Home route for %s while Discovery is unavailable", user_id)
            return stale
    if resp.status_code != 200:
        return None
    record = resp.json()
    home_node_url = record["home_node_url"]

    # Verify Discovery's Ed25519 signature on the user→home mapping.
    # This detects transport/cache tampering but does NOT protect against a
    # compromised Discovery signing key. User-signed BootstrapRecord and
    # RouteDescriptor are required for that stronger property (spec roadmap).
    # If Discovery doesn't yet include a signature (old version / key missing)
    # we log a warning and continue so existing deployments don't break.
    sig = record.get("record_signature")
    pubkey = record.get("discovery_public_key")
    if sig and pubkey:
        if not verify_user_record_response(
            user_id=user_id,
            home_node_url=home_node_url,
            updated_at=record.get("updated_at", ""),
            signature_b64=sig,
            public_key_b64=pubkey,
        ):
            logger.error(
                "BAD signature on Discovery user record for %s → %s — ignoring",
                user_id, home_node_url,
            )
            return None
    else:
        logger.debug(
            "Discovery user record for %s has no signature — accepting (upgrade Discovery to enable signing)",
            user_id,
        )

    _cache_store(_home_node_cache, user_id, home_node_url, now, settings.discovery_resolve_cache_ttl_seconds)
    _cache_store(
        _home_node_stale_cache,
        user_id,
        home_node_url,
        now,
        settings.discovery_resolve_stale_if_error_seconds,
    )
    return home_node_url


async def _list_discovery_nodes(capability: str, cluster_id: Optional[str]) -> list[str]:
    """Return relay-eligible node URLs sorted by Discovery-measured latency_ms.

    Latency is measured by Discovery's active health-check (health.py) and stored
    in the node_capabilities row. Nodes with no latency data yet sort last (∞).
    Sorting here means the _rank_reachable ping-race will usually confirm the
    already-fastest node first, rather than producing a random ordering.
    """
    if capability == "relay" and settings.signed_peer_selection_mode != "off":
        from app.peer_runtime import signed_relay_urls

        signed = signed_relay_urls()
        if signed:
            return signed
        if settings.signed_peer_selection_mode == "enforce":
            logger.warning("Signed peer selection is enforced but has no valid Relay set")
            return []
    if capability in {"storage", "media", "turn", "gateway"} and settings.signed_peer_selection_mode != "off":
        from app.peer_runtime import signed_capability_urls

        signed = signed_capability_urls(capability)
        if signed:
            return signed
        if settings.signed_peer_selection_mode == "enforce":
            logger.warning(
                "Signed peer selection is enforced but has no valid %s set",
                capability,
            )
            return []

    from shared.mesh.registry import get_mesh_registry

    registry = get_mesh_registry()
    cached = registry.urls_for_capability(capability, cluster_id=cluster_id)
    if cached:
        return cached

    params: dict[str, str] = {"capability": capability}
    if cluster_id:
        params["cluster_id"] = cluster_id
    async with httpx.AsyncClient(timeout=5.0) as client:
        try:
            resp = await client.get(f"{settings.discovery_url}/registry/nodes", params=params)
            resp.raise_for_status()
        except httpx.HTTPError as e:
            logger.warning("Discovery %s lookup failed: %s", capability, e)
            return []

    eligible = [
        node
        for node in resp.json().get("nodes", [])
        if node.get("status") == "online"
        and node.get("trust_status") == "trusted"
        # Only nodes with trust_level >= 1 are eligible as relay/transit.
        # Level 0 nodes serve only their own clients and must not carry
        # foreign messages. Level 1 (relay) and 2 (hub) are transit-eligible.
        and (node.get("trust_level") or 0) >= 1
    ]

    # Sort by latency_ms from Discovery's last health-check (lowest first).
    # Nodes that haven't been probed yet (latency_ms=None) sort to the end.
    def _latency(node: dict) -> float:
        m = node.get("metrics") or {}
        lat = m.get("latency_ms")
        return float(lat) if lat is not None else float("inf")

    eligible.sort(key=_latency)
    return [node["node_url"] for node in eligible]


async def _fastest_reachable(urls: list[str]) -> Optional[str]:
    """
    Races a /health ping against every candidate and returns whichever
    answers first — per 0203_ROUTING.md ("если недоступен, выбирает
    следующий по списку"), generalized from static list order to actual
    responsiveness so an unreachable/slow relay doesn't get picked over a
    live one just because it's earlier in Discovery's listing.
    """
    if not urls:
        return None

    async def ping(url: str) -> str:
        async with httpx.AsyncClient(timeout=RELAY_PING_TIMEOUT_SECONDS) as client:
            resp = await client.get(f"{url}/health")
            resp.raise_for_status()
            return url

    pending = {asyncio.create_task(ping(u)) for u in urls}
    try:
        while pending:
            done, pending = await asyncio.wait(pending, return_when=asyncio.FIRST_COMPLETED)
            for task in done:
                if task.exception() is None:
                    return task.result()
    finally:
        for task in pending:
            task.cancel()
    return None


async def _rank_reachable(urls: list[str]) -> list[str]:
    """
    Like _fastest_reachable but returns ALL relays that answered /health,
    ordered fastest-first. Lets the caller retry the actual forward on the
    next relay if the fastest one passes health but fails the real request
    or dies between the ping and the forward (retry-across-relays).
    """
    if not urls:
        return []

    async def ping(url: str) -> str:
        async with httpx.AsyncClient(timeout=RELAY_PING_TIMEOUT_SECONDS) as client:
            resp = await client.get(f"{url}/health")
            resp.raise_for_status()
            return url

    ranked: list[str] = []
    pending = {asyncio.create_task(ping(u)) for u in urls}
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


def _discovery_cluster_filter() -> Optional[str]:
    """Which cluster_id to pass to Discovery when resolving aux nodes."""
    if settings.resource_policy == "cluster":
        return settings.cluster_id
    if settings.resource_policy == "federated":
        return None
    return None  # local — no discovery lookup


async def _find_capability_node(capability: str) -> Optional[str]:
    if settings.resource_policy == "local":
        return None
    cluster_id = _discovery_cluster_filter()
    candidates = await _list_discovery_nodes(capability, cluster_id)
    return await _fastest_reachable(candidates)


async def _reachable_relays() -> list[str]:
    """All live relays from Discovery, fastest-first, for retry-across-relays."""
    if settings.resource_policy == "local":
        return []
    if settings.signed_peer_selection_mode != "off":
        from app.peer_runtime import signed_relay_urls, signed_reserve_urls

        active = signed_relay_urls()
        if active:
            reachable = await _rank_reachable(active)
            if reachable:
                return reachable
        reserves = signed_reserve_urls()
        if reserves:
            return await _rank_reachable(reserves)
        if settings.signed_peer_selection_mode == "enforce":
            return []
    cluster_id = _discovery_cluster_filter()
    candidates = await _list_discovery_nodes("relay", cluster_id)
    return await _rank_reachable(candidates)


async def _resolve_storage_url() -> str:
    return (await _resolve_storage_urls())[0]


async def _resolve_storage_urls() -> list[str]:
    """Return a bounded, de-duplicated Storage replica set.

    Discovery candidates are capability-filtered by the same registry path as
    other infrastructure services. Configured URLs remain a bootstrap/fallback
    set, including for local policy. The replication factor is deliberately
    capped in Settings so one message cannot create an unbounded fan-out.
    """
    configured = list(
        dict.fromkeys(
            [*settings.storage_node_urls, settings.storage_node_url.rstrip("/")]
        )
    )
    if settings.resource_policy == "local":
        selected = configured
    else:
        candidates = await _list_discovery_nodes(
            "storage", _discovery_cluster_filter()
        )
        reachable = await _rank_reachable(candidates)
        selected = (
            reachable
            if settings.signed_peer_selection_mode == "enforce"
            else list(dict.fromkeys([*reachable, *configured]))
        )
    if not selected:
        raise RuntimeError("No Storage Node is configured or discoverable")
    return selected[: settings.storage_replication_factor]


async def _resolve_media_url() -> str:
    discovered = await _find_capability_node("media")
    if discovered:
        return discovered
    if (
        settings.resource_policy != "local"
        and settings.signed_peer_selection_mode == "enforce"
    ):
        raise RuntimeError("No quorum-observed Media Node is available")
    return settings.media_node_url


async def _get_target_curve_public_key(home_node_url: str) -> Optional[str]:
    """Получить X25519 public key target Home-node из /health для sealed sender."""
    try:
        async with httpx.AsyncClient(timeout=3.0) as client:
            resp = await client.get(f"{home_node_url}/health")
            resp.raise_for_status()
            return resp.json().get("curve_public_key")
    except Exception as e:
        logger.debug("Could not fetch curve_public_key from %s: %s", home_node_url, e)
        return None


def _apply_sealed_sender(envelope: dict, receiver_curve_public_key_b64: str) -> dict:
    """Заменить открытый sender_user_id на sealed_sender_box в envelope.

    Sealed sender (Task #68): sender_user_id шифруется SealedBox (ECIES, anonymous)
    для receiver Home-node. Relay/hub видят только зашифрованный блоб.
    """
    sender_id = envelope.get("sender_user_id")
    if not sender_id:
        return envelope
    sealed = seal_sender(sender_id, receiver_curve_public_key_b64)
    sealed_env = dict(envelope)
    sealed_env["sealed_sender_box"] = sealed
    # Убираем открытый sender_user_id из federation envelope (relay его не видит)
    sealed_env.pop("sender_user_id", None)
    return sealed_env


async def deliver_to_remote_home_node(home_node_url: str, envelope: dict, conversation_meta: dict) -> None:
    """
    Delivery chain (0203_ROUTING.md + Phase 2.2/2.4):

      1. Direct: home-node → target home-node /internal/deliver
      2. Relay (L1/L2): home-node → relay /relay/forward → [relay escalates to hub]
      3. Storage buffer: recipient buffers on Storage Node so the message is not
         lost while the outbox retries asynchronously (backup route).

    Raises RuntimeError only after all three layers fail, so the caller
    (fanout.py) can enqueue to the durable outbox for later retry.
    """
    fs = get_federation_security()

    # Sealed sender (Task #68): шифруем sender_user_id для target Home-node
    # Relay nodes видят только sealed_sender_box — не знают кто отправитель.
    sealed_envelope = envelope
    target_curve_pk = await _get_target_curve_public_key(home_node_url)
    if target_curve_pk:
        sealed_envelope = _apply_sealed_sender(envelope, target_curve_pk)
        logger.debug("Sealed sender applied for %s", home_node_url)

    deliver_payload = build_deliver_payload(
        signing_key=fs.signing_key,
        origin_node_id=fs.node_id,
        envelope=sealed_envelope,
        conversation_meta=conversation_meta,
        route="direct",
        target_node_id=home_node_url,
    )

    async with httpx.AsyncClient(timeout=5.0) as client:
        try:
            resp = await federation_post(
                client,
                f"{home_node_url}/internal/deliver",
                path="/internal/deliver",
                payload=deliver_payload,
                signing_key=fs.signing_key,
                node_id=fs.node_id,
            )
            resp.raise_for_status()
            _fed_counters["direct_ok"] += 1
            return
        except httpx.HTTPError as e:
            logger.warning("Direct delivery to %s failed (%s), trying relay fallback", home_node_url, e)

    if settings.resource_policy == "local":
        _fed_counters["failed"] += 1
        raise RuntimeError(f"Direct delivery to {home_node_url} failed and relay fallback disabled (local policy)")

    relay_urls = await _reachable_relays()
    if not relay_urls:
        logger.warning(
            "Direct delivery to %s failed and no relay available — buffering to Storage Node",
            home_node_url,
        )
        await _buffer_envelope_for_recipients(envelope, conversation_meta)
        _fed_counters["buffer_ok"] += 1
        raise RuntimeError(f"Direct delivery to {home_node_url} failed and no relay available (buffered)")

    relay_payload = build_relay_forward_payload(
        signing_key=fs.signing_key,
        origin_node_id=fs.node_id,
        envelope=envelope,
        conversation_meta=conversation_meta,
        target_home_node_url=home_node_url,
        hop_count=1,  # first relay hop; relay-node may escalate to hub (hop 2)
    )
    # Retry across relays: a relay can pass /health yet fail the actual forward
    # (or die between ping and forward) — try the next live relay instead of
    # failing the whole delivery on the first one.
    transport_mode = settings.relay_transport_mode
    if transport_mode not in (
        "http", "websocket-preferred", "websocket-required",
        "quic-preferred", "quic-required",
    ):
        raise RuntimeError(f"Unsupported RELAY_TRANSPORT_MODE: {transport_mode}")

    last_error: Optional[Exception] = None
    for relay_url in relay_urls:
        try:
            await _get_relay_transport().forward(relay_url, relay_payload)
            _fed_counters["relay_ok"] += 1
            return
        except RelayTransportError as e:
            last_error = e
            logger.warning("Relay %s transport failed (%s), trying next relay", relay_url, e)

    # All relays (including their hub escalations) failed — buffer to Storage Node
    # so recipients can drain when connectivity recovers, and enqueue outbox retry.
    logger.warning(
        "All %d relay(s) failed for %s — buffering to Storage Node as backup route",
        len(relay_urls), home_node_url,
    )
    await _buffer_envelope_for_recipients(envelope, conversation_meta)
    _fed_counters["buffer_ok"] += 1
    raise RuntimeError(
        f"Direct delivery to {home_node_url} failed and all {len(relay_urls)} relay(s) failed (buffered)"
    ) from last_error


async def _buffer_envelope_for_recipients(envelope: dict, conversation_meta: dict) -> None:
    """Buffer the envelope to the Storage Node for each non-sender recipient in
    conversation_meta. This is the 'backup route' for Phase 2.4: even if all
    live delivery paths fail, the message lands in the Storage Node and will be
    drained when the recipient's home-node next reconnects (drain_buffer on WS
    connect) or when the outbox retry succeeds.

    Recipients are extracted from participant_user_ids minus the sender —
    consistent with how fanout.py identifies remote targets."""
    sender_id = envelope.get("sender_user_id")
    recipients = [
        uid
        for uid in conversation_meta.get("participant_user_ids", [])
        if uid != sender_id
    ]
    if not recipients:
        return
    for recipient_user_id in recipients:
        try:
            await buffer_for_offline_user(recipient_user_id, envelope)
        except Exception as buf_err:
            logger.warning(
                "Storage-node buffer fallback failed for %s: %s", recipient_user_id, buf_err
            )
            raise RuntimeError(
                f"Storage-node did not persist fallback for recipient {recipient_user_id}"
            ) from buf_err


async def buffer_for_offline_user(user_id: str, envelope: dict) -> None:
    """
    MVP simplification: Storage Node buffers are keyed by recipient_device_id
    per spec/0602_STORAGE_NODE.md, but this slice routes per-user rather than
    per-device (see app/fanout.py) — so we pass user_id into that field.
    Revisit when per-device multi-device fan-out is implemented.
    """
    storage_urls = await _resolve_storage_urls()
    fs = get_federation_security()
    buffer_payload = build_buffer_payload(
        signing_key=fs.signing_key,
        origin_node_id=fs.node_id,
        recipient_device_id=user_id,
        envelope=envelope,
        ttl_seconds=60 * 60 * 24 * 30,
    )
    async def store(storage_url: str) -> None:
        try:
            async with httpx.AsyncClient(timeout=5.0) as client:
                resp = await federation_post(
                    client,
                    f"{storage_url}/buffer",
                    path="/buffer",
                    payload=buffer_payload,
                    signing_key=fs.signing_key,
                    node_id=fs.node_id,
                )
                resp.raise_for_status()
        except Exception as exc:
            logger.warning(
                "Failed to buffer message for %s on %s: %s",
                user_id,
                storage_url,
                exc,
            )
            raise

    results = await asyncio.gather(
        *(store(storage_url) for storage_url in storage_urls),
        return_exceptions=True,
    )
    successful = sum(not isinstance(result, BaseException) for result in results)
    if successful < settings.storage_write_quorum:
        raise RuntimeError(
            "Storage write quorum was not reached "
            f"({successful}/{settings.storage_write_quorum})"
        )


async def drain_buffer(user_id: str, deliver: Callable[[dict], Awaitable[bool]]) -> None:
    """
    Fetch buffered envelopes and hand each to `deliver` (e.g. push over the
    just-connected WS). Only DELETE from the buffer once `deliver` reports a
    successful send — a push failure leaves the entry buffered for the next
    reconnect instead of being lost (see R3-message-lifecycle.md: DELETE
    buffer до client ACK / drain race).
    """
    storage_urls = await _resolve_storage_urls()
    fs = get_federation_security()
    copies_by_packet: dict[str, dict] = {}
    for storage_url in storage_urls:
        try:
            async with httpx.AsyncClient(timeout=5.0) as client:
                resp = await federation_get(
                    client,
                    f"{storage_url}/buffer/{user_id}",
                    path=f"/buffer/{user_id}",
                    signing_key=fs.signing_key,
                    node_id=fs.node_id,
                )
            if resp.status_code != 200:
                continue
            for entry in resp.json()["envelopes"]:
                envelope = entry["envelope"]
                packet_id = envelope.get("packet_id")
                if not isinstance(packet_id, str) or not packet_id:
                    packet_id = hashlib.sha256(
                        json.dumps(
                            envelope,
                            sort_keys=True,
                            separators=(",", ":"),
                        ).encode("utf-8")
                    ).hexdigest()
                group = copies_by_packet.setdefault(
                    packet_id, {"envelope": envelope, "copies": []}
                )
                group["copies"].append((storage_url, entry["id"]))
        except (httpx.HTTPError, KeyError, TypeError, ValueError) as exc:
            logger.warning(
                "Failed to drain buffer for %s from %s: %s",
                user_id,
                storage_url,
                exc,
            )

    for group in copies_by_packet.values():
        try:
            delivered = await deliver(group["envelope"])
        except Exception:
            delivered = False
        if not delivered:
            continue
        for storage_url, entry_id in group["copies"]:
            try:
                async with httpx.AsyncClient(timeout=5.0) as client:
                    await federation_delete(
                        client,
                        f"{storage_url}/buffer/{entry_id}",
                        path=f"/buffer/{entry_id}",
                        signing_key=fs.signing_key,
                        node_id=fs.node_id,
                    )
            except httpx.HTTPError:
                pass
