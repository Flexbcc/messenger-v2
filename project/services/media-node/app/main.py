import os

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.config_loader import get_settings
from app.config import settings as node_settings
from app.db import init_db
from app.node_registration import start_node_registration
from app.routers import admin_storage, media
from app.storage_service import purge_expired
from shared.mesh.install import install_mesh
from shared.security.health import security_health_snapshot
from shared.security.nonce_cleanup import start_nonce_cleanup

app = FastAPI(title="Media Node", version="0.2.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.on_event("startup")
async def on_startup():
    init_db()
    purge_expired()
    start_node_registration()
    from app.media_auth import get_federation_security
    start_nonce_cleanup(get_federation_security().nonce_store)


@app.get("/health")
def health():
    settings = get_settings()
    files_count = 0
    bytes_total = 0
    root = settings.media.local_path
    if os.path.isdir(root):
        for name in os.listdir(root):
            path = os.path.join(root, name)
            if os.path.isfile(path):
                files_count += 1
                bytes_total += os.path.getsize(path)
    return {
        "status": "ok",
        "node_role": "media",
        "load": {
            "files_count": files_count,
            "bytes_total": bytes_total,
            "primary_backend": settings.media.primary_backend,
            "cache_ttl_hours": settings.media.network_cache_ttl_hours,
        },
        "security": security_health_snapshot(),
    }


app.include_router(media.router)
app.include_router(admin_storage.router)

install_mesh(
    app,
    discovery_url=node_settings.discovery_url,
    node_id=node_settings.node_id,
    cluster_id=node_settings.cluster_id,
)
