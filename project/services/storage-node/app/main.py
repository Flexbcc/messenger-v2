from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from app.db import get_conn, init_db
from app.node_registration import start_node_registration
from app.routers import buffer
from app.config import settings
from shared.mesh.install import install_mesh
from shared.security.health import security_health_snapshot

app = FastAPI(title="Storage Node", version="0.1.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # MVP only, see home-node/app/main.py for the same note
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.on_event("startup")
async def on_startup():
    init_db()
    start_node_registration()


@app.get("/health")
def health():
    with get_conn() as conn:
        buffered_count = conn.execute("SELECT COUNT(*) FROM buffered_envelopes").fetchone()[0]
    return {"status": "ok", "node_role": "storage", "load": {"buffered_count": buffered_count}, "security": security_health_snapshot()}


app.include_router(buffer.router)

install_mesh(
    app,
    discovery_url=settings.discovery_url,
    node_id=settings.node_id,
    cluster_id=settings.cluster_id,
)
