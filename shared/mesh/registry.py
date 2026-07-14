"""In-memory mesh peer cache for routing (ADR-0006 bootstrap push)."""
from __future__ import annotations

import threading
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Dict, Iterable, List, Optional


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


@dataclass
class MeshPeer:
    node_id: str
    node_url: str
    capabilities: List[str]
    cluster_id: str
    software_version: str
    trust_status: str
    first_seen: str = field(default_factory=_now_iso)
    last_seen: str = field(default_factory=_now_iso)


class MeshPeerRegistry:
    def __init__(self) -> None:
        self._lock = threading.RLock()
        self._peers: Dict[str, MeshPeer] = {}
        self._self_node_id: str = ""
        self._cluster_id: str = "default"

    def configure(self, *, self_node_id: str, cluster_id: str) -> None:
        with self._lock:
            self._self_node_id = self_node_id
            self._cluster_id = cluster_id

    def upsert_peer(
        self,
        *,
        node_id: str,
        node_url: str,
        capabilities: Iterable[str],
        cluster_id: str,
        software_version: str = "unknown",
        trust_status: str = "trusted",
    ) -> None:
        if node_id == self._self_node_id:
            return
        caps = list(capabilities)
        now = _now_iso()
        with self._lock:
            existing = self._peers.get(node_id)
            if existing:
                existing.node_url = node_url
                existing.capabilities = caps
                existing.cluster_id = cluster_id
                existing.software_version = software_version
                existing.trust_status = trust_status
                existing.last_seen = now
            else:
                self._peers[node_id] = MeshPeer(
                    node_id=node_id,
                    node_url=node_url,
                    capabilities=caps,
                    cluster_id=cluster_id,
                    software_version=software_version,
                    trust_status=trust_status,
                    first_seen=now,
                    last_seen=now,
                )

    def replace_from_discovery(
        self,
        nodes: Iterable[dict],
        *,
        self_node_id: str,
        cluster_id: Optional[str] = None,
    ) -> int:
        """Full sync from GET /registry/nodes — returns number of peers stored."""
        count = 0
        with self._lock:
            self._self_node_id = self_node_id
            if cluster_id:
                self._cluster_id = cluster_id
            keep: Dict[str, MeshPeer] = {}
            for raw in nodes:
                if raw.get("trust_status") != "trusted":
                    continue
                node_id = raw.get("node_id") or ""
                if not node_id or node_id == self_node_id:
                    continue
                if cluster_id and raw.get("cluster_id", "default") != cluster_id:
                    continue
                caps = raw.get("capabilities") or []
                now = _now_iso()
                prev = self._peers.get(node_id)
                keep[node_id] = MeshPeer(
                    node_id=node_id,
                    node_url=raw.get("node_url") or "",
                    capabilities=list(caps),
                    cluster_id=raw.get("cluster_id") or "default",
                    software_version=raw.get("software_version") or "unknown",
                    trust_status="trusted",
                    first_seen=prev.first_seen if prev else now,
                    last_seen=now,
                )
                count += 1
            self._peers = keep
        return count

    def urls_for_capability(
        self,
        capability: str,
        *,
        cluster_id: Optional[str] = None,
    ) -> List[str]:
        with self._lock:
            peers = list(self._peers.values())
        urls: List[str] = []
        for peer in peers:
            if peer.trust_status != "trusted":
                continue
            if capability not in peer.capabilities:
                continue
            if cluster_id and peer.cluster_id != cluster_id:
                continue
            if peer.node_url and peer.node_url not in urls:
                urls.append(peer.node_url)
        return urls

    def list_peers(self) -> List[MeshPeer]:
        with self._lock:
            return sorted(self._peers.values(), key=lambda p: p.node_id)

    @property
    def self_node_id(self) -> str:
        return self._self_node_id

    @property
    def cluster_id(self) -> str:
        return self._cluster_id


_registry = MeshPeerRegistry()


def get_mesh_registry() -> MeshPeerRegistry:
    return _registry
