"""Wire mesh router + Discovery sync into a FastAPI node app."""
from __future__ import annotations

from fastapi import FastAPI

from shared.mesh.registry import get_mesh_registry
from shared.mesh.router import create_mesh_router
from shared.mesh.sync import start_mesh_sync


def install_mesh(
    app: FastAPI,
    *,
    discovery_url: str,
    node_id: str,
    cluster_id: str = "default",
) -> None:
    get_mesh_registry().configure(self_node_id=node_id, cluster_id=cluster_id)
    app.include_router(create_mesh_router())

    @app.on_event("startup")
    async def _mesh_on_startup() -> None:
        start_mesh_sync(
            discovery_url=discovery_url,
            self_node_id=node_id,
            cluster_id=cluster_id,
        )
