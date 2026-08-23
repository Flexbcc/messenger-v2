"""Turn Node — issues time-limited TURN credentials for calls (see
spec/0605_TURN_NODE.md, spec/0303_CALLS.md, ADR-0008). Does not itself
relay media — see README.md for what still needs a real TURN server."""
import asyncio

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.config import settings, validate_turn_configuration
from app.node_registration import start_node_registration
from app.turn_auth import TurnAuthDep
from app.turn_credentials import issue_credentials
from shared.security.health import security_health_snapshot
from shared.security.relay_challenge_receiver import install_relay_challenge_receiver
from app.fed_security import get_federation_security

app = FastAPI(title="Turn Node", version="0.1.0")
install_relay_challenge_receiver(app, get_federation_security)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # MVP only, see home-node/app/main.py for the same note
    allow_methods=["*"],
    allow_headers=["*"],
)

_credentials_issued = 0
_probe_task: asyncio.Task | None = None


@app.on_event("startup")
async def on_startup():
    global _probe_task
    validate_turn_configuration()
    start_node_registration()
    from app.turn_probe import probe_loop
    _probe_task = asyncio.create_task(probe_loop())


@app.on_event("shutdown")
async def on_shutdown():
    global _probe_task
    if _probe_task is not None:
        _probe_task.cancel()
        await asyncio.gather(_probe_task, return_exceptions=True)
        _probe_task = None
    from app.node_registration import stop_node_registration
    await stop_node_registration()


@app.get("/health")
def health():
    from app.turn_probe import turn_probe_status
    from app.node_registration import node_registration_status, runtime_node_id
    return {
        "status": "ok",
        "node_role": "turn",
        "node_id": runtime_node_id(),
        "node_alias": settings.node_id,
        "load": {"credentials_issued": _credentials_issued},
        "turn_contract": {
            "realm": settings.realm,
            "udp": settings.enable_udp,
            "tcp": settings.enable_tcp,
            "tls": settings.enable_tls,
            "credential_ttl_seconds": settings.credential_ttl_seconds,
            "client_policy": "relay",
        },
        "coturn": turn_probe_status(),
        "security": security_health_snapshot(),
        "runtime": {"capabilities": settings.capabilities, "registration": node_registration_status()},
    }


@app.post("/turn/credentials")
def turn_credentials(_caller: dict = TurnAuthDep):
    """
    Issues short-lived TURN REST credentials.
    Signed mode requires device JWT (same as home-node).
    """
    global _credentials_issued
    _credentials_issued += 1
    return issue_credentials()
