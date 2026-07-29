from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from app.db import get_conn, init_db
from app.node_registration import start_node_registration
from app.routers import buffer
from app.config import settings
from shared.mesh.install import install_mesh
from shared.security.health import security_health_snapshot
from shared.security.nonce_cleanup import start_nonce_cleanup

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
    from app.fed_security import get_federation_security
    start_nonce_cleanup(get_federation_security().nonce_store)


@app.get("/health")
def health():
    from shared.security.config import BUFFER_MAX_ENTRIES_PER_RECIPIENT, BUFFER_EVICTION_POLICY
    with get_conn() as conn:
        buffered_count = conn.execute("SELECT COUNT(*) FROM buffered_envelopes").fetchone()[0]
        # Топ-5 получателей с наибольшим числом буферизованных сообщений
        top_rows = conn.execute(
            """SELECT recipient_device_id, COUNT(*) as cnt
               FROM buffered_envelopes
               GROUP BY recipient_device_id
               ORDER BY cnt DESC LIMIT 5"""
        ).fetchall()
    top_recipients = [{"device_id": r[0], "count": r[1]} for r in top_rows]
    return {
        "status": "ok",
        "node_role": "storage",
        "load": {
            "buffered_count": buffered_count,
            "buffer_limit_per_recipient": BUFFER_MAX_ENTRIES_PER_RECIPIENT,
            "buffer_eviction_policy": BUFFER_EVICTION_POLICY,
            "top_recipients": top_recipients,
        },
        "security": security_health_snapshot(),
    }


app.include_router(buffer.router)

install_mesh(
    app,
    discovery_url=settings.discovery_url,
    node_id=settings.node_id,
    cluster_id=settings.cluster_id,
)
