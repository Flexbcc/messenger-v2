"""Periodic mesh sync from Discovery + initial bootstrap pull."""
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
