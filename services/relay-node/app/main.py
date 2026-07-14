"""Relay Node — real packet forwarding (see spec/0601_RELAY_NODE.md, ADR-0006)."""
import httpx
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware

from app.config import settings
from app.fed_security import FederationAuthDep, get_federation_security
from app.node_registration import start_node_registration
from shared.mesh.install import install_mesh
from shared.security.envelope_verify import verify_incoming_federation
from shared.security.health import security_health_snapshot
from shared.security.http_client import federation_post

app = FastAPI(title="Relay Node", version="0.1.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # MVP only, see home-node/app/main.py for the same note
    allow_methods=["*"],
    allow_headers=["*"],
)

_forwarded_count = 0


@app.on_event("startup")
async def on_startup():
    start_node_registration()


@app.get("/health")
def health():
    return {
        "status": "ok",
        "node_role": "relay",
        "node_id": settings.node_id,
        "load": {"forwarded_count": _forwarded_count},
        "security": security_health_snapshot(),
    }


@app.post("/relay/forward")
async def forward(payload: dict, _verified: str = FederationAuthDep):
    """
    Forwards a Packet to its next hop. Relay does not read/decrypt content
    (payload['envelope']['ciphertext'] stays opaque) — it only routes.
    """
    global _forwarded_count

    target_url = payload.get("target_home_node_url")
    if not target_url:
        raise HTTPException(status_code=400, detail="target_home_node_url is required")

    envelope = payload["envelope"]
    conversation_meta = payload["conversation_meta"]
    federation = payload.get("federation")

    fs = get_federation_security()
    await verify_incoming_federation(
        federation=federation,
        envelope=envelope,
        endpoint="/relay/forward",
        trust_cache=fs.trust_cache,
        nonce_store=fs.nonce_store,
        audit=fs.audit_log,
        expected_origin_node_id=federation.get("origin_node_id") if federation else None,
        consume_nonce=False,
    )

    origin = federation.get("origin_node_id", settings.node_id) if federation else settings.node_id
    deliver_payload = {
        "envelope": envelope,
        "conversation_meta": conversation_meta,
        "origin_node_id": origin,
    }
    if federation is not None:
        deliver_payload["federation"] = federation

    async with httpx.AsyncClient(timeout=10.0) as client:
        try:
            resp = await federation_post(
                client,
                f"{target_url}/internal/deliver",
                path="/internal/deliver",
                payload=deliver_payload,
                signing_key=fs.signing_key,
                node_id=fs.node_id,
            )
            resp.raise_for_status()
        except httpx.HTTPError as e:
            raise HTTPException(status_code=502, detail=f"Relay forward failed: {e}")

    _forwarded_count += 1
    return {"status": "forwarded"}


install_mesh(
    app,
    discovery_url=settings.discovery_url,
    node_id=settings.node_id,
    cluster_id=settings.cluster_id,
)
