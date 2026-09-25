import asyncio
import logging

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from shared.security.cors_config import client_allowed_origins
from app.db import get_conn, init_db
from app.node_registration import start_node_registration
from app.routers import buffer, challenge
from app.config import settings, validate_security_configuration
from shared.mesh.install import install_mesh
from shared.security.health import security_health_snapshot
from shared.security.nonce_cleanup import start_nonce_cleanup
from shared.security.body_limit import FederationBodyLimitMiddleware
from shared.security.relay_challenge_receiver import install_relay_challenge_receiver
from app.fed_security import get_federation_security

app = FastAPI(title="Storage Node", version="0.1.0")
logger = logging.getLogger(__name__)
install_relay_challenge_receiver(app, get_federation_security)
_nonce_cleanup_task: asyncio.Task | None = None
_expired_data_cleanup_task: asyncio.Task | None = None


async def _expired_data_cleanup_loop() -> None:
    """Physically remove expired ciphertext even when nobody polls Storage."""
    while True:
        try:
            await asyncio.sleep(60)
            from datetime import datetime, timezone

            now = datetime.now(timezone.utc).isoformat()
            with get_conn() as conn:
                conn.execute(
                    "DELETE FROM buffered_envelopes WHERE expires_at <= ?", (now,)
                )
                conn.execute(
                    "DELETE FROM opaque_mailbox_cells WHERE expires_at <= ?", (now,)
                )
                conn.execute(
                    "DELETE FROM synthetic_challenge_cells WHERE expires_at <= ?",
                    (now,),
                )
                conn.commit()
        except asyncio.CancelledError:
            break
        except Exception:
            logger.exception("expired Storage data cleanup failed")

app.add_middleware(
    FederationBodyLimitMiddleware,
    path_prefixes=("/buffer", "/mailbox/", "/internal/challenge/"),
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=client_allowed_origins(),
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.on_event("startup")
async def on_startup():
    global _nonce_cleanup_task, _expired_data_cleanup_task
    validate_security_configuration()
    init_db()
    if settings.advertise_to_network:
        start_node_registration()
    else:
        logger.info(
            "Storage network participation is disabled; local mailbox remains available"
        )
    from app.fed_security import get_federation_security
    _nonce_cleanup_task = start_nonce_cleanup(get_federation_security().nonce_store)
    _expired_data_cleanup_task = asyncio.create_task(_expired_data_cleanup_loop())


@app.on_event("shutdown")
async def on_shutdown():
    global _nonce_cleanup_task, _expired_data_cleanup_task
    tasks = [
        task
        for task in (_nonce_cleanup_task, _expired_data_cleanup_task)
        if task is not None
    ]
    for task in tasks:
        task.cancel()
    if tasks:
        await asyncio.gather(*tasks, return_exceptions=True)
    _nonce_cleanup_task = None
    _expired_data_cleanup_task = None
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
        "runtime": {
            "local_mailbox_available": True,
            "advertised_to_network": settings.advertise_to_network,
            "capabilities": settings.capabilities,
            "registration": node_registration_status(),
        },
    }


app.include_router(buffer.router)
app.include_router(challenge.router)

install_mesh(
    app,
    discovery_url=settings.discovery_url,
    node_id=settings.node_id,
    cluster_id=settings.cluster_id,
)
