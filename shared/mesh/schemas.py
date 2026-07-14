from typing import List, Optional

from pydantic import BaseModel, Field


class MeshPeerRecord(BaseModel):
    node_id: str
    node_url: str
    capabilities: List[str] = Field(default_factory=list)
    cluster_id: str = "default"
    software_version: str = "unknown"
    trust_status: str = "trusted"


class MeshPeerJoinedRequest(BaseModel):
    """Discovery → existing node: a new peer joined the mesh."""

    event: str = "peer_joined"
    source: str = "discovery"
    peer: MeshPeerRecord


class MeshPeerListResponse(BaseModel):
    peers: List[MeshPeerRecord]
    self_node_id: str
    cluster_id: str
