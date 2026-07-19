"""
Federation client — adapted from the RoutingService/forward_to_peer pattern
in ~/secure-messenger-project/backend/app/services/routing.py (ADR-0005),
but resolving addresses via a dedicated Discovery Node instead of
broadcasting to every configured peer.
"""
from __future__ import annotations

import asyncio
import logging
from typing import Optional

import httpx

from app.config import settings
from app.fed_security import get_federation_security
from shared.security.http_client import federation_delete, federation_get, federation_post
from shared.security.payload_builder import build_buffer_payload, build_deliver_payload, build_relay_forward_payload

logger = logging.getLogger(__name__)

RELAY_PING_TIMEOUT_SECONDS = 3.0


async def publish_user_to_discovery(
    user_id: str,
    display_name: str,
    auth_public_key: str,
    login: str | None = None,
    username_search_enabled: bool = True,
) -> None:
    async with httpx.AsyncClient(timeout=5.0) as client:
        try:
            body = {
                "user_id": user_id,
                "home_node_url": settings.public_url,
                "display_name": display_name,
                "auth_public_key": auth_public_key,
                "cluster_id": settings.cluster_id,
                "login": login,
                "username_search_enabled": username_search_enabled,
            }
            await client.post(
                f"{settings.discovery_url}/registry/users",
                json=body,
            )
        except httpx.HTTPError as e:
            logger.warning("Failed to publish user %s to discovery: %s", user_id, e)


async def resolve_home_node(user_id: str) -> Optional[str]:
    """Returns the Home Node public URL hosting user_id, or None if unknown."""
    async with httpx.AsyncClient(timeout=5.0) as client:
        try:
            resp = await client.get(f"{settings.discovery_url}/registry/users/{user_id}")
        except httpx.HTTPError as e:
            logger.warning("Discovery lookup failed for %s: %s", user_id, e)
            return None
    if resp.status_code == 200:
        return resp.json()["home_node_url"]
    return None


async def _list_discovery_nodes(capability: str, cluster_id: Optional[str]) -> list[str]:
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
    return [
        node["node_url"]
        for node in resp.json().get("nodes", [])
        if node.get("status") == "online" and node.get("trust_status") == "trusted"
    ]


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
    cluster_id = _discovery_cluster_filter()
    candidates = await _list_discovery_nodes("relay", cluster_id)
    return await _rank_reachable(candidates)


async def _resolve_storage_url() -> str:
    discovered = await _find_capability_node("storage")
    if discovered:
        return discovered
    return settings.storage_node_url


async def _resolve_media_url() -> str:
    discovered = await _find_capability_node("media")
    if discovered:
        return discovered
    return settings.media_node_url


async def deliver_to_remote_home_node(home_node_url: str, envelope: dict, conversation_meta: dict) -> None:
    """
    Direct delivery first (lowest latency, per 0203_ROUTING.md); on failure,
    fall back to a live Relay Node from Discovery Node's registry (ADR-0006).
    """
    fs = get_federation_security()
    deliver_payload = build_deliver_payload(
        signing_key=fs.signing_key,
        origin_node_id=settings.node_id,
        envelope=envelope,
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
            return
        except httpx.HTTPError as e:
            logger.warning("Direct delivery to %s failed (%s), trying relay fallback", home_node_url, e)

    if settings.resource_policy == "local":
        raise RuntimeError(f"Direct delivery to {home_node_url} failed and relay fallback disabled (local policy)")

    relay_urls = await _reachable_relays()
    if not relay_urls:
        raise RuntimeError(f"Direct delivery to {home_node_url} failed and no relay available")

    relay_payload = build_relay_forward_payload(
        signing_key=fs.signing_key,
        origin_node_id=settings.node_id,
        envelope=envelope,
        conversation_meta=conversation_meta,
        target_home_node_url=home_node_url,
    )
    # Retry across relays: a relay can pass /health yet fail the actual forward
    # (or die between ping and forward) — try the next live relay instead of
    # failing the whole delivery on the first one.
    last_error: Optional[Exception] = None
    async with httpx.AsyncClient(timeout=10.0) as client:
        for relay_url in relay_urls:
            try:
                resp = await federation_post(
                    client,
                    f"{relay_url}/relay/forward",
                    path="/relay/forward",
                    payload=relay_payload,
                    signing_key=fs.signing_key,
                    node_id=fs.node_id,
                )
                resp.raise_for_status()
                return
            except httpx.HTTPError as e:
                last_error = e
                logger.warning(
                    "Relay %s forward failed (%s), trying next relay", relay_url, e
                )
    raise RuntimeError(
        f"Direct delivery to {home_node_url} failed and all {len(relay_urls)} "
        f"relay(s) failed"
    ) from last_error


async def buffer_for_offline_user(user_id: str, envelope: dict) -> None:
    """
    MVP simplification: Storage Node buffers are keyed by recipient_device_id
    per spec/0602_STORAGE_NODE.md, but this slice routes per-user rather than
    per-device (see app/fanout.py) — so we pass user_id into that field.
    Revisit when per-device multi-device fan-out is implemented.
    """
    storage_url = await _resolve_storage_url()
    fs = get_federation_security()
    buffer_payload = build_buffer_payload(
        signing_key=fs.signing_key,
        origin_node_id=settings.node_id,
        recipient_device_id=user_id,
        envelope=envelope,
        ttl_seconds=60 * 60 * 24 * 30,
    )
    async with httpx.AsyncClient(timeout=5.0) as client:
        try:
            resp = await federation_post(
                client,
                f"{storage_url}/buffer",
                path="/buffer",
                payload=buffer_payload,
                signing_key=fs.signing_key,
                node_id=fs.node_id,
            )
            resp.raise_for_status()
        except httpx.HTTPError as e:
            logger.warning("Failed to buffer message for %s: %s", user_id, e)


async def drain_buffer(user_id: str) -> list[dict]:
    storage_url = await _resolve_storage_url()
    fs = get_federation_security()
    async with httpx.AsyncClient(timeout=5.0) as client:
        try:
            resp = await federation_get(
                client,
                f"{storage_url}/buffer/{user_id}",
                path=f"/buffer/{user_id}",
                signing_key=fs.signing_key,
                node_id=fs.node_id,
            )
        except httpx.HTTPError as e:
            logger.warning("Failed to drain buffer for %s: %s", user_id, e)
            return []
    if resp.status_code != 200:
        return []
    entries = resp.json()["envelopes"]
    for entry in entries:
        try:
            async with httpx.AsyncClient(timeout=5.0) as client:
                await federation_delete(
                    client,
                    f"{storage_url}/buffer/{entry['id']}",
                    path=f"/buffer/{entry['id']}",
                    signing_key=fs.signing_key,
                    node_id=fs.node_id,
                )
        except httpx.HTTPError:
            pass
    return [entry["envelope"] for entry in entries]
