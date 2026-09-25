"""Home-side multi-Discovery transport peer quorum and local route planning."""

from __future__ import annotations

import asyncio
from datetime import datetime, timezone
from typing import Any

import httpx
from shared.security.outbound_tls import outbound_tls_verify

from app.config import settings
from app.fed_security import get_federation_security
from shared.transport.route_builder import (
    TransportPeer,
    choose_route,
    eligible_gossip_transport_peers,
    transport_candidate_commitment,
)


_last_error: str | None = None
_last_planned_at: datetime | None = None


async def _fetch_view(client: httpx.AsyncClient, origin: str) -> tuple[str, list[dict[str, Any]]]:
    response = await client.get(
        f"{origin.rstrip('/')}/registry/node-advertisements/peer-view",
        params={"capability": "relay", "minimum_sources": 2},
    )
    response.raise_for_status()
    payload = response.json()
    candidates = payload.get("candidates")
    if not isinstance(candidates, list) or len(candidates) > 1000:
        raise ValueError("invalid transport peer view")
    return origin, [item for item in candidates if isinstance(item, dict)]


async def plan_transport_route() -> tuple[TransportPeer, ...]:
    global _last_error, _last_planned_at
    origins = tuple(settings.route_discovery_urls)
    if len(origins) < settings.route_minimum_discovery_sources:
        raise ValueError("insufficient Discovery sources for transport route")
    async with httpx.AsyncClient(timeout=5.0, follow_redirects=False, trust_env=False, verify=outbound_tls_verify()) as client:
        results = await asyncio.gather(
            *(_fetch_view(client, origin) for origin in origins),
            return_exceptions=True,
        )
    variants: dict[str, dict[str, list[tuple[str, dict[str, Any]]]]] = {}
    for result in results:
        if isinstance(result, Exception):
            continue
        origin, candidates = result
        for candidate in candidates:
            node_id = candidate.get("node_id")
            if not isinstance(node_id, str):
                continue
            try:
                encoded = transport_candidate_commitment(candidate)
            except ValueError:
                continue
            variants.setdefault(node_id, {}).setdefault(encoded, []).append((origin, candidate))
    agreed: list[dict[str, Any]] = []
    for node_id, node_variants in variants.items():
        if len(node_variants) != 1:
            continue
        observations = next(iter(node_variants.values()))
        if len({origin for origin, _candidate in observations}) >= settings.route_minimum_discovery_sources:
            agreed.append(observations[0][1])
    try:
        peers = eligible_gossip_transport_peers(agreed, now=datetime.now(timezone.utc))
        own_node_id = get_federation_security().identity_node_id
        route = choose_route(
            peers,
            hop_count=settings.transport_route_hops,
            excluded_node_ids=(own_node_id,) if own_node_id else (),
        )
    except Exception as exc:
        _last_error = str(exc)
        raise
    _last_error = None
    _last_planned_at = datetime.now(timezone.utc)
    return route


def transport_route_status() -> dict[str, Any]:
    return {
        "hop_count": settings.transport_route_hops,
        "minimum_discovery_sources": settings.route_minimum_discovery_sources,
        "last_planned_at": (
            _last_planned_at.isoformat().replace("+00:00", "Z")
            if _last_planned_at else None
        ),
        "last_error": _last_error,
    }
