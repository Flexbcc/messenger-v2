import json
import time
from typing import Optional

import httpx

from shared.security.config import TRUST_CACHE_TTL_SECONDS


class TrustCache:
    def __init__(self, discovery_url: str):
        self._discovery_url = discovery_url.rstrip("/")
        self._entries: dict[str, dict] = {}
        self._fetched_at = 0.0

    async def _refresh(self) -> None:
        now = time.time()
        if now - self._fetched_at < TRUST_CACHE_TTL_SECONDS and self._entries:
            return
        async with httpx.AsyncClient(timeout=5.0) as client:
            resp = await client.get(f"{self._discovery_url}/registry/nodes")
            resp.raise_for_status()
            nodes = resp.json().get("nodes", [])
        self._entries = {n["node_id"]: n for n in nodes}
        self._fetched_at = now

    async def get_node(self, node_id: str) -> Optional[dict]:
        await self._refresh()
        return self._entries.get(node_id)

    async def is_trusted(self, node_id: str) -> bool:
        node = await self.get_node(node_id)
        if not node:
            return False
        return node.get("trust_status", "trusted") == "trusted"

    async def signing_public_key(self, node_id: str) -> Optional[str]:
        node = await self.get_node(node_id)
        if not node:
            return None
        return node.get("signing_public_key")

    async def has_capability(self, node_id: str, capability: str) -> bool:
        node = await self.get_node(node_id)
        if not node:
            return False
        caps = node.get("capabilities") or []
        return capability in caps
