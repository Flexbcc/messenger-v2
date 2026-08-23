import asyncio

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from app.db import get_conn, init_db
from app.node_registration import start_node_registration
from app.routers import buffer, challenge
from app.config import settings
from shared.mesh.install import install_mesh
from shared.security.health import security_health_snapshot
from shared.security.nonce_cleanup import start_nonce_cleanup
from shared.security.body_limit import FederationBodyLimitMiddleware
from shared.security.relay_challenge_receiver import install_relay_challenge_receiver
from app.fed_security import get_federation_security

app = FastAPI(title="Storage Node", version="0.1.0")
install_relay_challenge_receiver(app, get_federation_security)
_nonce_cleanup_task: asyncio.Task | None = None

app.add_middleware(
    FederationBodyLimitMiddleware,
    path_prefixes=("/buffer", "/mailbox/", "/internal/challenge/"),
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # MVP only, see home-node/app/main.py for the same note
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.on_event("startup")
async def on_startup():
    global _nonce_cleanup_task
    init_db()
    start_node_registration()
    from app.fed_security import get_federation_security
    _nonce_cleanup_task = start_nonce_cleanup(get_federation_security().nonce_store)


@app.on_event("shutdown")
async def on_shutdown():
    global _nonce_cleanup_task
    if _nonce_cleanup_task is not None:
        _nonce_cleanup_task.cancel()
        await asyncio.gather(_nonce_cleanup_task, return_exceptions=True)
        _nonce_cleanup_task = None
    from app.node_registration import stop_node_registration
    await stop_node_registration()


@app.get("/health")
def health():
    from shared.security.config import BUFFER_MAX_ENTRIES_PER_RECIPIENT, BUFFER_EVICTION_POLICY
    from app.fed_security import get_federation_security
    fs = get_federation_security()
    from app.node_registration import node_registration_status
    with get_conn() as conn:
        buffered_count = conn.execute("SELECT COUNT(*) FROM buffered_envelopes").fetchone()[0]
        opaque_mailbox_cell_count = conn.execute(
            "SELECT COUNT(*) FROM opaque_mailbox_cells"
        ).fetchone()[0]
        opaque_mailbox_bytes = conn.execute(
            "SELECT COALESCE(SUM(cell_size), 0) FROM opaque_mailbox_cells"
        ).fetchone()[0]
    return {
        "status": "ok",
        "node_role": "storage",
        "node_id": fs.node_id,
        "node_alias": settings.node_id,
        "load": {
            "buffered_count": buffered_count,
            "buffer_limit_per_recipient": BUFFER_MAX_ENTRIES_PER_RECIPIENT,
            "buffer_eviction_policy": BUFFER_EVICTION_POLICY,
            "opaque_mailbox_cell_count": opaque_mailbox_cell_count,
            "opaque_mailbox_bytes": opaque_mailbox_bytes,
            "opaque_mailbox_capacity_bytes": settings.max_opaque_storage_bytes,
            "max_padded_poll_bytes": settings.max_padded_poll_bytes,
        },
        "security": security_health_snapshot(),
        "runtime": {"capabilities": settings.capabilities, "registration": node_registration_status()},
    }


app.include_router(buffer.router)
app.include_router(challenge.router)

install_mesh(
    app,
    discovery_url=settings.discovery_url,
    node_id=settings.node_id,
    cluster_id=settings.cluster_id,
)
