"""Relay integration for the provider-neutral MixIngressRuntime."""

from __future__ import annotations

import asyncio
import time
from datetime import datetime, timezone
from functools import lru_cache
from typing import Any
from urllib.parse import urlparse

import httpx
from shared.security.outbound_tls import outbound_tls_verify

from app.config import settings
from app.fed_security import get_federation_security
from shared.security.http_client import federation_post
from shared.security.transport_credentials import load_or_create_transport_key
from shared.transport.mix_pool import MixPool
from shared.transport.mix_runtime import MixIngressRuntime
from shared.transport.onion_provider import OnionPacketProvider, UnavailableOnionProvider
from shared.transport.opaque_ingress import build_opaque_ingress_packet
from shared.transport.replay_tag_store import ReplayTagStore
from shared.transport.route_builder import (
    eligible_gossip_transport_peers,
    transport_candidate_commitment,
)


_provider: OnionPacketProvider = UnavailableOnionProvider()
_drain_task: asyncio.Task | None = None
_last_error: str | None = None
_peer_cache: dict[str, tuple[float, str]] = {}
_peer_cache_lock = asyncio.Lock()


def _discovery_origin(value: str) -> str:
    parsed = urlparse(value)
    if (
        parsed.scheme not in {"http", "https"}
        or not parsed.hostname
        or parsed.username is not None
        or parsed.password is not None
        or parsed.path not in {"", "/"}
        or parsed.params
        or parsed.query
        or parsed.fragment
    ):
        raise ValueError("Mix Discovery URL must be an http(s) origin")
    return value.rstrip("/")


def install_onion_provider(provider: OnionPacketProvider) -> None:
    """Process-start hook; replacement after runtime creation is forbidden."""
    global _provider
    if get_mix_runtime.cache_info().currsize:
        raise RuntimeError("cannot replace onion provider after Mix runtime creation")
    if not provider.provider_id or provider.provider_id == "unavailable":
        raise ValueError("a concrete reviewed onion provider is required")
    _provider = provider


async def _fetch_peer_view(
    client: httpx.AsyncClient, origin: str
) -> tuple[str, list[dict[str, Any]]]:
    response = await client.get(
        f"{origin}/registry/node-advertisements/peer-view",
        params={"minimum_sources": 2},
    )
    response.raise_for_status()
    candidates = response.json().get("candidates")
    if not isinstance(candidates, list) or len(candidates) > 1000:
        raise ValueError("invalid Mix peer view")
    return origin, [item for item in candidates if isinstance(item, dict)]


def _parse_cache_deadline(value: Any) -> datetime:
    if not isinstance(value, str):
        raise ValueError("missing peer validity deadline")
    parsed = datetime.fromisoformat(
        value[:-1] + "+00:00" if value.endswith("Z") else value
    )
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        raise ValueError("peer validity deadline must include timezone")
    return parsed.astimezone(timezone.utc)


async def _resolve_next_node_uncached(
    node_id: str, required_capability: str
) -> tuple[str, float]:
    if required_capability not in {"relay", "home"}:
        raise ValueError("invalid required Mix hop capability")
    origins = tuple(_discovery_origin(value) for value in settings.mix_discovery_urls)
    if len(origins) < settings.mix_minimum_discovery_sources:
        raise RuntimeError("insufficient Discovery sources for next Mix hop")
    async with httpx.AsyncClient(
        timeout=5.0, follow_redirects=False, trust_env=False, verify=outbound_tls_verify()
    ) as client:
        results = await asyncio.gather(
            *(_fetch_peer_view(client, origin) for origin in origins),
            return_exceptions=True,
        )
    variants: dict[str, list[tuple[str, dict[str, Any]]]] = {}
    for result in results:
        if isinstance(result, Exception):
            continue
        origin, candidates = result
        for candidate in candidates:
            if (
                candidate.get("node_id") != node_id
                or required_capability not in candidate.get("capabilities", [])
            ):
                continue
            try:
                commitment = transport_candidate_commitment(candidate)
            except ValueError:
                continue
            variants.setdefault(commitment, []).append((origin, candidate))
    agreed = [
        entries[0][1]
        for entries in variants.values()
        if len({origin for origin, _candidate in entries})
        >= settings.mix_minimum_discovery_sources
    ]
    if len(agreed) != 1:
        raise RuntimeError("next Mix hop lacks a unique Discovery quorum")
    peers = eligible_gossip_transport_peers(
        agreed,
        now=datetime.now(timezone.utc),
        allowed_capabilities=("relay", "home"),
    )
    own_node_id = get_federation_security().identity_node_id
    matches = [
        peer for peer in peers
        if peer.node_id == node_id
        and peer.node_id != own_node_id
        and required_capability in peer.capabilities
    ]
    if len(matches) != 1:
        raise RuntimeError("next Mix hop certificate or endpoint is invalid")
    try:
        advertisement_deadline = _parse_cache_deadline(
            agreed[0]["advertisement_expires_at"]
        )
        operational_deadline = _parse_cache_deadline(
            agreed[0]["operational_valid_until"]
        )
        observation_deadline = _parse_cache_deadline(
            agreed[0]["observation_valid_until"]
        )
        capability_deadline = _parse_cache_deadline(
            agreed[0]["capability_valid_until"]
        )
        certificate_deadline = _parse_cache_deadline(
            agreed[0]["transport_certificate"]["valid_until"]
        )
    except (KeyError, TypeError, ValueError) as exc:
        raise RuntimeError("next Mix hop validity deadline is invalid") from exc
    remaining = (
        min(
            advertisement_deadline,
            observation_deadline,
            operational_deadline,
            capability_deadline,
            certificate_deadline,
        )
        - datetime.now(timezone.utc)
    ).total_seconds()
    if remaining <= 0:
        raise RuntimeError("next Mix hop signed state expired")
    return matches[0].endpoint.rstrip("/"), remaining


async def _resolve_next_node(node_id: str, required_capability: str) -> str:
    cache_key = f"{required_capability}:{node_id}"
    now = time.monotonic()
    cached = _peer_cache.get(cache_key)
    if cached and cached[0] > now:
        return cached[1]
    async with _peer_cache_lock:
        now = time.monotonic()
        cached = _peer_cache.get(cache_key)
        if cached and cached[0] > now:
            return cached[1]
        endpoint, signed_lifetime = await _resolve_next_node_uncached(
            node_id, required_capability
        )
        for key in [key for key, value in _peer_cache.items() if value[0] <= now]:
            _peer_cache.pop(key, None)
        if len(_peer_cache) >= settings.mix_peer_cache_max_records:
            oldest = min(_peer_cache, key=lambda key: _peer_cache[key][0])
            _peer_cache.pop(oldest, None)
        _peer_cache[cache_key] = (
            now + min(settings.mix_peer_cache_ttl_seconds, signed_lifetime),
            endpoint,
        )
        return endpoint


async def trusted_home_endpoint(target_url: str) -> bool:
    """Validate a legacy Basic Relay target through the quorum peer view."""
    try:
        normalized = target_url.rstrip("/")
        origins = tuple(
            _discovery_origin(value) for value in settings.mix_discovery_urls
        )
        if len(origins) < settings.mix_minimum_discovery_sources:
            return False
        async with httpx.AsyncClient(
            timeout=5.0, follow_redirects=False, trust_env=False, verify=outbound_tls_verify()
        ) as client:
            results = await asyncio.gather(
                *(_fetch_peer_view(client, origin) for origin in origins),
                return_exceptions=True,
            )
        variants: dict[tuple[str, str], list[tuple[str, dict[str, Any]]]] = {}
        for result in results:
            if isinstance(result, Exception):
                continue
            origin, candidates = result
            for candidate in candidates:
                capabilities = candidate.get("capabilities")
                endpoint = candidate.get("endpoint")
                if (
                    not isinstance(endpoint, str)
                    or endpoint.rstrip("/") != normalized
                    or not isinstance(capabilities, list)
                    or "home" not in capabilities
                ):
                    continue
                node_id = candidate.get("node_id")
                if not isinstance(node_id, str):
                    continue
                try:
                    commitment = transport_candidate_commitment(candidate)
                except (TypeError, ValueError):
                    continue
                variants.setdefault((node_id, commitment), []).append(
                    (origin, candidate)
                )
        agreed = [
            observations[0][1]
            for observations in variants.values()
            if len({origin for origin, _item in observations})
            >= settings.mix_minimum_discovery_sources
        ]
        if len(agreed) != 1:
            return False
        peers = eligible_gossip_transport_peers(
            agreed,
            now=datetime.now(timezone.utc),
            allowed_capabilities=("home",),
        )
        return len(peers) == 1 and peers[0].endpoint.rstrip("/") == normalized
    except (KeyError, TypeError, ValueError, httpx.HTTPError):
        return False


async def trusted_relay_endpoints(*, minimum_level: int = 0) -> list[str]:
    """Return quorum-observed, locally verified Relay endpoints.

    If a subject has multiple quorum-backed commitments, it is excluded. This
    makes a Discovery split view fail closed rather than selecting by ordering.
    """
    try:
        origins = tuple(
            _discovery_origin(value) for value in settings.mix_discovery_urls
        )
        if len(origins) < settings.mix_minimum_discovery_sources:
            return []
        async with httpx.AsyncClient(
            timeout=5.0, follow_redirects=False, trust_env=False, verify=outbound_tls_verify()
        ) as client:
            results = await asyncio.gather(
                *(_fetch_peer_view(client, origin) for origin in origins),
                return_exceptions=True,
            )
        variants: dict[tuple[str, str], list[tuple[str, dict[str, Any]]]] = {}
        for result in results:
            if isinstance(result, Exception):
                continue
            origin, candidates = result
            for candidate in candidates:
                capabilities = candidate.get("capabilities")
                node_id = candidate.get("node_id")
                level = candidate.get("level")
                if (
                    not isinstance(node_id, str)
                    or not isinstance(level, int)
                    or isinstance(level, bool)
                    or level < minimum_level
                    or not isinstance(capabilities, list)
                    or "relay" not in capabilities
                ):
                    continue
                try:
                    commitment = transport_candidate_commitment(candidate)
                except (TypeError, ValueError):
                    continue
                variants.setdefault((node_id, commitment), []).append(
                    (origin, candidate)
                )

        quorum_by_node: dict[str, list[dict[str, Any]]] = {}
        for (node_id, _commitment), observations in variants.items():
            if (
                len({origin for origin, _candidate in observations})
                >= settings.mix_minimum_discovery_sources
            ):
                quorum_by_node.setdefault(node_id, []).append(observations[0][1])
        agreed = [
            candidates[0]
            for candidates in quorum_by_node.values()
            if len(candidates) == 1
        ]
        peers = eligible_gossip_transport_peers(
            agreed,
            now=datetime.now(timezone.utc),
            allowed_capabilities=("relay",),
        )
        own_node_id = get_federation_security().identity_node_id
        return sorted(
            {
                peer.endpoint.rstrip("/")
                for peer in peers
                if peer.node_id != own_node_id
            }
        )
    except (KeyError, TypeError, ValueError, RuntimeError, httpx.HTTPError):
        return []


async def _send_next(
    node_id: str, capability: str, packet: bytes, expires_at: datetime
) -> None:
    target = await _resolve_next_node(node_id, capability)
    fs = get_federation_security()
    payload = build_opaque_ingress_packet(
        packet, expires_at=expires_at
    )
    async with httpx.AsyncClient(timeout=10.0, follow_redirects=False, trust_env=False, verify=outbound_tls_verify()) as client:
        response = await federation_post(
            client,
            f"{target}/mix/ingress",
            path="/mix/ingress",
            payload=payload,
            signing_key=fs.signing_key,
            node_id=fs.node_id,
        )
        response.raise_for_status()


async def _reject_final(_payload: bytes) -> None:
    raise RuntimeError("Relay-only node cannot terminate a Mix route")


@lru_cache
def get_mix_runtime() -> MixIngressRuntime:
    private_key = load_or_create_transport_key(settings.transport_key_path)
    return MixIngressRuntime(
        provider=_provider,
        private_key=bytes(private_key),
        replay_store=ReplayTagStore(
            settings.mix_replay_db_path,
            ttl_seconds=settings.mix_replay_ttl_seconds,
            max_records=settings.mix_replay_max_records,
        ),
        pool=MixPool(
            max_cells=settings.mix_pool_max_cells,
            max_bytes=settings.mix_pool_max_bytes,
            min_delay_seconds=settings.mix_min_delay_ms / 1000,
            max_delay_seconds=settings.mix_max_delay_ms / 1000,
        ),
        next_hop_sender=_send_next,
        final_delivery=_reject_final,
    )


async def _drain_loop() -> None:
    global _last_error
    while True:
        try:
            await get_mix_runtime().drain(batch_limit=settings.mix_drain_batch)
            _last_error = None
        except Exception as exc:
            _last_error = str(exc)
        await asyncio.sleep(0.05)


def start_mix_runtime() -> asyncio.Task:
    global _drain_task
    if _drain_task and not _drain_task.done():
        raise RuntimeError("Mix runtime already started")
    if settings.onion_provider_mode == "sidecar":
        origins = tuple(
            _discovery_origin(value) for value in settings.mix_discovery_urls
        )
        if len(origins) < settings.mix_minimum_discovery_sources:
            raise RuntimeError(
                "sidecar Mix mode requires independent Discovery quorum"
            )
    if (
        settings.onion_provider_mode == "sidecar"
        and _provider.provider_id == "unavailable"
    ):
        from shared.transport.onion_sidecar import OnionSidecarProvider
        install_onion_provider(
            OnionSidecarProvider(settings.onion_sidecar_socket_path)
        )
    _drain_task = asyncio.create_task(_drain_loop())
    return _drain_task


async def stop_mix_runtime() -> None:
    global _drain_task
    if _drain_task:
        _drain_task.cancel()
        await asyncio.gather(_drain_task, return_exceptions=True)
        _drain_task = None
    close = getattr(_provider, "close", None)
    if close is not None:
        await close()


async def mix_status() -> dict[str, Any]:
    status = await get_mix_runtime().health()
    status["last_error"] = _last_error
    status["discovery_sources"] = len(settings.mix_discovery_urls)
    status["minimum_discovery_sources"] = settings.mix_minimum_discovery_sources
    status["peer_cache_records"] = len(_peer_cache)
    status["peer_cache_max_records"] = settings.mix_peer_cache_max_records
    return status
