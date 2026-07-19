"""FastAPI routes for mesh peer cache (internal)."""
from __future__ import annotations

import os

from fastapi import APIRouter, Header, HTTPException

from shared.mesh.registry import get_mesh_registry
from shared.mesh.schemas import MeshPeerJoinedRequest, MeshPeerListResponse, MeshPeerRecord

MESH_NOTIFY_SECRET = os.environ.get("MESH_NOTIFY_SECRET", "")


def _check_mesh_notify_secret(x_mesh_notify_secret: str | None) -> None:
    if not MESH_NOTIFY_SECRET:
        return
    if not x_mesh_notify_secret or x_mesh_notify_secret != MESH_NOTIFY_SECRET:
        raise HTTPException(status_code=403, detail="Invalid mesh notify secret")


def create_mesh_router() -> APIRouter:
    router = APIRouter(prefix="/internal/mesh", tags=["mesh"])

    @router.post("/peer-joined")
    def peer_joined(
        payload: MeshPeerJoinedRequest,
        x_mesh_notify_secret: str | None = Header(None, alias="X-Mesh-Notify-Secret"),
    ):
        """
        Discovery (main server) notifies this node that a new peer registered.
        Existing nodes merge the peer into their local routing cache immediately
        instead of waiting for the next GET /registry/nodes poll.
        """
        _check_mesh_notify_secret(x_mesh_notify_secret)
        peer = payload.peer
        if peer.trust_status != "trusted":
            return {"status": "ignored", "reason": "peer not trusted"}

        registry = get_mesh_registry()
        registry.upsert_peer(
            node_id=peer.node_id,
            node_url=peer.node_url,
            capabilities=peer.capabilities,
            cluster_id=peer.cluster_id,
            software_version=peer.software_version,
            trust_status=peer.trust_status,
        )
        return {"status": "ok", "node_id": peer.node_id}

    @router.get("/peers", response_model=MeshPeerListResponse)
    def list_mesh_peers():
        registry = get_mesh_registry()
        return MeshPeerListResponse(
            peers=[
                MeshPeerRecord(
                    node_id=p.node_id,
                    node_url=p.node_url,
                    capabilities=p.capabilities,
                    cluster_id=p.cluster_id,
                    software_version=p.software_version,
                    trust_status=p.trust_status,
                )
                for p in registry.list_peers()
            ],
            self_node_id=registry.self_node_id,
            cluster_id=registry.cluster_id,
        )

    return router
