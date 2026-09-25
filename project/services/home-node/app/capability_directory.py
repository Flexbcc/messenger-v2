"""Discovery-backed infrastructure selection and reachability ranking."""

import asyncio
import logging
import math
from typing import Optional
from urllib.parse import urlparse

import httpx

from app.config import settings
from shared.security.http_response import get_bounded_json
from shared.security.outbound_tls import outbound_tls_verify


logger = logging.getLogger(__name__)
RELAY_PING_TIMEOUT_SECONDS = 3.0
MAX_DISCOVERY_RESPONSE_BYTES = 2 * 1024 * 1024


def _origin(value: object) -> str | None:
    if not isinstance(value, str) or len(value) > 2048:
        return None
    try:
        parsed = urlparse(value)
        port = parsed.port
    except ValueError:
        return None
    if (
        parsed.scheme not in {"http", "https"}
        or not parsed.hostname
        or parsed.username is not None
        or parsed.password is not None
        or parsed.path not in {"", "/"}
        or parsed.params
        or parsed.query
        or parsed.fragment
        or (port is not None and not 1 <= port <= 65535)
    ):
        return None
    return value.rstrip("/")


async def list_discovery_nodes(
    capability: str, cluster_id: Optional[str]
) -> list[str]:
    """Return trusted capability URLs ordered by Discovery latency."""
    if capability == "relay" and settings.signed_peer_selection_mode != "off":
        from app.peer_runtime import signed_relay_urls

        signed = signed_relay_urls()
        if signed:
            return signed
        if settings.signed_peer_selection_mode == "enforce":
            logger.warning(
                "Signed peer selection is enforced but has no valid Relay set"
            )
            return []
    if (
        capability in {"storage", "media", "turn", "gateway"}
        and settings.signed_peer_selection_mode != "off"
    ):
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

    cached = get_mesh_registry().urls_for_capability(
        capability, cluster_id=cluster_id
    )
    if cached:
        return cached

    params: dict[str, str] = {"capability": capability}
    if cluster_id:
        params["cluster_id"] = cluster_id
    async with httpx.AsyncClient(
        timeout=5.0,
        follow_redirects=False,
        trust_env=False,
        verify=outbound_tls_verify(),
    ) as client:
        try:
            status_code, payload = await get_bounded_json(
                client,
                f"{settings.discovery_url}/registry/nodes",
                params=params,
                max_bytes=MAX_DISCOVERY_RESPONSE_BYTES,
            )
            if status_code >= 400:
                raise ValueError(f"Discovery returned HTTP {status_code}")
        except (httpx.HTTPError, ValueError) as error:
            logger.warning("Discovery %s lookup failed: %s", capability, error)
            return []
    if not isinstance(payload, dict):
        return []
    nodes = payload.get("nodes")
    if not isinstance(nodes, list) or len(nodes) > 10_000:
        logger.warning("Discovery %s lookup returned an invalid node list", capability)
        return []

    eligible = [
        node
        for node in nodes
        if isinstance(node, dict)
        and _origin(node.get("node_url")) is not None
        and node.get("status") == "online"
        and node.get("trust_status") == "trusted"
        and isinstance(node.get("trust_level"), int)
        and not isinstance(node.get("trust_level"), bool)
        and node["trust_level"] >= 1
    ]

    def latency(node: dict) -> float:
        metrics = node.get("metrics")
        value = metrics.get("latency_ms") if isinstance(metrics, dict) else None
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            return float("inf")
        numeric = float(value)
        return max(0.0, numeric) if math.isfinite(numeric) else float("inf")

    eligible.sort(key=latency)
    return [origin for node in eligible if (origin := _origin(node["node_url"]))]


async def _ping(url: str) -> str:
    origin = _origin(url)
    if origin is None:
        raise ValueError("invalid node origin")
    async with httpx.AsyncClient(
        timeout=RELAY_PING_TIMEOUT_SECONDS,
        follow_redirects=False,
        trust_env=False,
    ) as client:
        response = await client.get(f"{origin}/health")
        response.raise_for_status()
        return origin


async def rank_reachable(urls: list[str]) -> list[str]:
    """Return all candidates that answer `/health`, fastest first."""
    pending = {asyncio.create_task(_ping(url)) for url in dict.fromkeys(urls)}
    ranked: list[str] = []
    try:
        while pending:
            done, pending = await asyncio.wait(
                pending, return_when=asyncio.FIRST_COMPLETED
            )
            for task in done:
                if not task.cancelled() and task.exception() is None:
                    ranked.append(task.result())
    finally:
        for task in pending:
            task.cancel()
        if pending:
            await asyncio.gather(*pending, return_exceptions=True)
    return ranked


async def fastest_reachable(urls: list[str]) -> Optional[str]:
    """Return the first candidate that answers, cancelling slower probes."""
    pending = {asyncio.create_task(_ping(url)) for url in dict.fromkeys(urls)}
    try:
        while pending:
            done, pending = await asyncio.wait(
                pending, return_when=asyncio.FIRST_COMPLETED
            )
            for task in done:
                if not task.cancelled() and task.exception() is None:
                    return task.result()
    finally:
        for task in pending:
            task.cancel()
        if pending:
            await asyncio.gather(*pending, return_exceptions=True)
    return None
