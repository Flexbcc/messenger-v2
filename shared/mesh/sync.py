"""Periodic mesh sync from Discovery + initial bootstrap pull + heartbeat peer update."""
from __future__ import annotations

import asyncio
import logging
import os
from typing import Optional

import httpx

from shared.mesh.registry import get_mesh_registry

logger = logging.getLogger(__name__)

MESH_SYNC_INTERVAL_SECONDS = int(os.environ.get("MESH_SYNC_INTERVAL_SECONDS", "300"))
MESH_SYNC_CLUSTER_ONLY = os.environ.get("MESH_SYNC_CLUSTER_ONLY", "false").lower() in (
    "1",
    "true",
    "yes",
    "on",
)


async def sync_mesh_from_discovery(
    *,
    discovery_url: str,
    self_node_id: str,
    cluster_id: str,
) -> int:
    registry = get_mesh_registry()
    registry.configure(self_node_id=self_node_id, cluster_id=cluster_id)

    params: dict[str, str] = {}
    if MESH_SYNC_CLUSTER_ONLY:
        params["cluster_id"] = cluster_id

    async with httpx.AsyncClient(timeout=10.0) as client:
        resp = await client.get(f"{discovery_url.rstrip('/')}/registry/nodes", params=params or None)
        resp.raise_for_status()
        nodes = resp.json().get("nodes", [])

    count = registry.replace_from_discovery(
        nodes,
        self_node_id=self_node_id,
        cluster_id=cluster_id if MESH_SYNC_CLUSTER_ONLY else None,
    )
    logger.info("Mesh sync: %d trusted peer(s) from Discovery", count)
    return count


async def _mesh_sync_loop(
    *,
    discovery_url: str,
    self_node_id: str,
    cluster_id: str,
) -> None:
    while True:
        await asyncio.sleep(MESH_SYNC_INTERVAL_SECONDS)
        try:
            await sync_mesh_from_discovery(
                discovery_url=discovery_url,
                self_node_id=self_node_id,
                cluster_id=cluster_id,
            )
        except Exception as exc:
            logger.warning("Mesh periodic sync failed: %s", exc)


def update_mesh_from_heartbeat_response(
    response_data: dict,
    *,
    self_node_id: str,
    cluster_id: Optional[str] = None,
) -> int:
    """Обновить mesh-кэш из поля `peers` в heartbeat-ответе Discovery (Фаза 3.3).

    Вызывается из _heartbeat_once() каждой ноды после успешного heartbeat.
    Позволяет держать peer-кэш актуальным без отдельного GET /registry/nodes.
    Возвращает количество обновлённых peers (0 если поля нет или пусто).
    """
    peers = response_data.get("peers")
    if not peers:
        return 0

    registry = get_mesh_registry()
    registry.configure(self_node_id=self_node_id, cluster_id=cluster_id or "default")

    count = 0
    for peer in peers:
        node_id = peer.get("node_id") or ""
        node_url = peer.get("node_url") or ""
        if not node_id or not node_url or node_id == self_node_id:
            continue
        peer_cluster = peer.get("cluster_id", "default")
        if cluster_id and peer_cluster != cluster_id:
            continue
        registry.upsert_peer(
            node_id=node_id,
            node_url=node_url,
            capabilities=peer.get("capabilities") or [],
            cluster_id=peer_cluster,
            software_version=peer.get("software_version", "unknown"),
            trust_status="trusted",
        )
        count += 1

    if count:
        logger.debug("Mesh update from heartbeat: %d peer(s) refreshed", count)
    return count


def start_mesh_sync(
    *,
    discovery_url: str,
    self_node_id: str,
    cluster_id: str = "default",
) -> None:
    """Bootstrap pull + background refresh (best-effort, non-blocking)."""

    async def _init() -> None:
        try:
            await sync_mesh_from_discovery(
                discovery_url=discovery_url,
                self_node_id=self_node_id,
                cluster_id=cluster_id,
            )
        except Exception as exc:
            logger.warning("Initial mesh sync failed (will retry): %s", exc)
        asyncio.create_task(
            _mesh_sync_loop(
                discovery_url=discovery_url,
                self_node_id=self_node_id,
                cluster_id=cluster_id,
            )
        )

    asyncio.create_task(_init())
