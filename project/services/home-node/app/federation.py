"""
Federation client — adapted from the RoutingService/forward_to_peer pattern
in ~/secure-messenger-project/backend/app/services/routing.py (ADR-0005),
but resolving addresses via a dedicated Discovery Node instead of
broadcasting to every configured peer.
"""
from __future__ import annotations

import json
import logging
import time
from typing import Awaitable, Callable, Optional

import httpx

from app.config import settings
from app.delivery_metrics import record_delivery_stage
from app.fed_security import get_federation_security
from app.federation_records import validate_user_home_record
from app.home_route_cache import HomeRouteCache
from shared.security.http_client import federation_post
from shared.security.http_response import get_bounded_json, parse_bounded_json_response
from shared.security.outbound_tls import outbound_tls_verify
from shared.security.sealed_sender import seal_sender
from shared.transport.relay_adapter import RelayTransportAdapter
from shared.transport.ws_relay_client import RelayTransportError
from shared.security.payload_builder import (
    build_deliver_payload,
    build_delivery_ack_payload,
    build_home_changed_payload,
    build_relay_forward_payload,
)
from app.storage_buffer_client import (
    buffer_for_offline_user as write_offline_buffer,
    drain_buffer as drain_storage_buffer,
    purge_buffered_packet as purge_storage_buffered_packet,
)
from app.capability_directory import (
    fastest_reachable,
    list_discovery_nodes,
    rank_reachable,
)

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Federation delivery counters — сбрасываются при рестарте процесса.
# Отдаются в /health → load.federation для admin UI.
# ---------------------------------------------------------------------------
_fed_counters: dict[str, int] = {
    "direct_ok": 0,       # успешная прямая доставка
    "relay_ok": 0,        # успешная доставка через relay/hub
    "buffer_ok": 0,       # сообщение ушло в Storage Node buffer
    "failed": 0,          # все пути отказали (сообщение потеряно или в outbox)
    "home_online_accepted": 0,
    "home_mailbox_accepted": 0,
    "device_acked": 0,
    "delivery_completed": 0,
    "mailbox_replicas_purged": 0,
}


def get_federation_counters() -> dict[str, int]:
    return dict(_fed_counters)


def record_device_ack() -> None:
    """Count a semantic endpoint ACK separately from transport acceptance."""
    _fed_counters["device_acked"] += 1


def record_delivery_completed() -> None:
    """Count a Home copy that reached its complete endpoint ACK set."""
    _fed_counters["delivery_completed"] += 1


def record_mailbox_purge(replicas: int) -> None:
    """Count only Storage replicas that confirmed deletion after full ACK."""
    if isinstance(replicas, int) and not isinstance(replicas, bool) and replicas > 0:
        _fed_counters["mailbox_replicas_purged"] += replicas


def get_transport_runtime_status() -> dict[str, object]:
    """Privacy-safe transport state for local health and operator UI."""
    if _relay_transport is None:
        return {
            "initialized": False,
            "mode": settings.relay_transport_mode,
            "websocket": {
                "active_links": 0,
                "tracked_links": 0,
                "max_links": settings.relay_max_persistent_peers,
            },
            "quic_initialized": False,
        }
    return {"initialized": True, **_relay_transport.status_snapshot()}


# Route caches are bounded and mutate synchronously between await points, so
# single-process asyncio callers cannot interleave an individual operation.
_home_node_cache = HomeRouteCache()
_home_node_stale_cache = HomeRouteCache()
_relay_transport: RelayTransportAdapter | None = None
_direct_http_client: httpx.AsyncClient | None = None
_curve_key_cache: dict[str, tuple[Optional[str], float]] = {}
_CURVE_KEY_CACHE_TTL_SECONDS = 300.0
_CURVE_KEY_NEGATIVE_CACHE_TTL_SECONDS = 15.0


def _get_direct_http_client() -> httpx.AsyncClient:
    """Shared keep-alive pool for the latency-sensitive Home-to-Home path."""
    global _direct_http_client
    if _direct_http_client is None:
        _direct_http_client = httpx.AsyncClient(
            timeout=5.0,
            follow_redirects=False,
            trust_env=False,
            verify=outbound_tls_verify(),
            limits=httpx.Limits(
                max_connections=settings.direct_max_connections,
                max_keepalive_connections=settings.direct_max_keepalive_connections,
                keepalive_expiry=float(settings.direct_keepalive_expiry_seconds),
            ),
        )
    return _direct_http_client


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
            websocket_max_links=settings.relay_max_persistent_peers,
            websocket_idle_timeout_seconds=settings.relay_link_idle_seconds,
        )
    return _relay_transport


async def close_relay_transport() -> None:
    global _relay_transport, _direct_http_client
    relay_client = _relay_transport
    _relay_transport = None
    direct_client = _direct_http_client
    _direct_http_client = None
    if relay_client is not None:
        await relay_client.close()
    if direct_client is not None:
        await direct_client.aclose()
    _curve_key_cache.clear()


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
    async with httpx.AsyncClient(
        timeout=5.0,
        follow_redirects=False,
        trust_env=False,
        verify=outbound_tls_verify(),
    ) as client:
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
            fs = get_federation_security()
            resp = await federation_post(
                client,
                f"{settings.discovery_url}/registry/users",
                path="/registry/users",
                payload=body,
                signing_key=fs.signing_key,
                node_id=fs.node_id,
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
    async with httpx.AsyncClient(
        timeout=5.0,
        follow_redirects=False,
        trust_env=False,
        verify=outbound_tls_verify(),
    ) as client:
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
    from_device_id: str,
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
        from_device_id=from_device_id,
        acked_at=acked_at,
        target_node_id=target_home_node_url,
    )
    async with httpx.AsyncClient(
        timeout=5.0,
        follow_redirects=False,
        trust_env=False,
        verify=outbound_tls_verify(),
    ) as client:
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
        cached = _home_node_cache.lookup(user_id, now=now)
        if cached is not None:
            return cached

    async with httpx.AsyncClient(
        timeout=5.0,
        follow_redirects=False,
        trust_env=False,
        verify=outbound_tls_verify(),
    ) as client:
        try:
            status_code, record = await get_bounded_json(
                client,
                f"{settings.discovery_url}/registry/users/{user_id}",
                max_bytes=256 * 1024,
            )
        except (httpx.HTTPError, ValueError) as e:
            logger.warning("Discovery lookup failed for %s: %s", user_id, e)
            stale = _home_node_stale_cache.lookup(user_id, now=now)
            if stale is not None:
                logger.warning("Using last-known Home route for %s while Discovery is unavailable", user_id)
            return stale
    if status_code != 200:
        return None
    if not isinstance(record, dict):
        logger.error("Discovery returned an invalid record for user %s", user_id)
        return None
    home_node_url, record_error = validate_user_home_record(
        record,
        expected_user_id=user_id,
        require_signature=settings.internal_security_mode == "signed",
        trusted_public_keys=settings.discovery_signing_public_keys,
    )
    if home_node_url is None:
        logger.error("Rejected Discovery route for %s: %s", user_id, record_error)
        return None

    _home_node_cache.store(
        user_id,
        home_node_url,
        now=now,
        ttl_seconds=settings.discovery_resolve_cache_ttl_seconds,
    )
    _home_node_stale_cache.store(
        user_id,
        home_node_url,
        now=now,
        ttl_seconds=settings.discovery_resolve_stale_if_error_seconds,
    )
    return home_node_url


async def _list_discovery_nodes(capability: str, cluster_id: Optional[str]) -> list[str]:
    return await list_discovery_nodes(capability, cluster_id)


async def _fastest_reachable(urls: list[str]) -> Optional[str]:
    return await fastest_reachable(urls)


async def _rank_reachable(urls: list[str]) -> list[str]:
    return await rank_reachable(urls)


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
    now = time.monotonic()
    cached = _curve_key_cache.get(home_node_url)
    if cached is not None:
        key, expires_at = cached
        if now < expires_at:
            return key
        _curve_key_cache.pop(home_node_url, None)
    try:
        status_code, payload = await get_bounded_json(
            _get_direct_http_client(),
            f"{home_node_url}/health",
            max_bytes=64 * 1024,
        )
        key = None
        if status_code == 200 and isinstance(payload, dict):
            candidate = payload.get("curve_public_key")
            if isinstance(candidate, str) and len(candidate) <= 128:
                key = candidate
        ttl = (
            _CURVE_KEY_CACHE_TTL_SECONDS
            if key is not None
            else _CURVE_KEY_NEGATIVE_CACHE_TTL_SECONDS
        )
        _curve_key_cache[home_node_url] = (key, now + ttl)
        return key
    except Exception as e:
        logger.debug("Could not fetch curve_public_key from %s: %s", home_node_url, e)
        _curve_key_cache[home_node_url] = (
            None,
            now + _CURVE_KEY_NEGATIVE_CACHE_TTL_SECONDS,
        )
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
    key_lookup_started = time.perf_counter()
    target_curve_pk = await _get_target_curve_public_key(home_node_url)
    record_delivery_stage(
        "target_key_lookup", (time.perf_counter() - key_lookup_started) * 1000
    )
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

    direct_started = time.perf_counter()
    try:
        resp = await federation_post(
            _get_direct_http_client(),
            f"{home_node_url}/internal/deliver",
            path="/internal/deliver",
            payload=deliver_payload,
            signing_key=fs.signing_key,
            node_id=fs.node_id,
        )
        resp.raise_for_status()
        response_payload = parse_bounded_json_response(resp, max_bytes=16 * 1024)
        if not isinstance(response_payload, dict) or response_payload.get("status") != "home_accepted":
            raise RuntimeError("Target Home returned an invalid acceptance response")
        acceptance = response_payload.get("acceptance")
        if acceptance in ("online", "mixed"):
            _fed_counters["home_online_accepted"] += 1
        if acceptance in ("mailbox", "mixed"):
            _fed_counters["home_mailbox_accepted"] += 1
        record_delivery_stage(
            "direct_home_request", (time.perf_counter() - direct_started) * 1000
        )
        _fed_counters["direct_ok"] += 1
        return
    except (httpx.HTTPError, RuntimeError, ValueError) as e:
        record_delivery_stage(
            "direct_home_request", (time.perf_counter() - direct_started) * 1000
        )
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
    storage_urls = await _resolve_storage_urls()
    fs = get_federation_security()
    await write_offline_buffer(
        user_id,
        envelope,
        storage_urls=storage_urls,
        write_quorum=settings.storage_write_quorum,
        signing_key=fs.signing_key,
        node_id=fs.node_id,
        ttl_seconds=settings.offline_mailbox_ttl_seconds,
    )


async def drain_buffer(user_id: str, deliver: Callable[[dict], Awaitable[bool]]) -> None:
    storage_urls = await _resolve_storage_urls()
    fs = get_federation_security()
    await drain_storage_buffer(
        user_id,
        deliver,
        storage_urls=storage_urls,
        signing_key=fs.signing_key,
        node_id=fs.node_id,
    )


async def purge_acknowledged_mailbox_packet(user_id: str, packet_id: str) -> int:
    """Release all known Storage replicas only after the endpoint ACK."""
    storage_urls = await _resolve_storage_urls()
    fs = get_federation_security()
    return await purge_storage_buffered_packet(
        user_id,
        packet_id,
        storage_urls=storage_urls,
        signing_key=fs.signing_key,
        node_id=fs.node_id,
    )
