"""Turn Node — issues time-limited TURN credentials for calls (see
spec/0605_TURN_NODE.md, spec/0303_CALLS.md, ADR-0008). Does not itself
relay media — see README.md for what still needs a real TURN server."""
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.config import settings
from app.node_registration import start_node_registration
from app.turn_auth import TurnAuthDep
from app.turn_credentials import issue_credentials
from shared.security.health import security_health_snapshot

app = FastAPI(title="Turn Node", version="0.1.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # MVP only, see home-node/app/main.py for the same note
    allow_methods=["*"],
    allow_headers=["*"],
)

_credentials_issued = 0


@app.on_event("startup")
async def on_startup():
    start_node_registration()


@app.get("/health")
def health():
    return {
        "status": "ok",
        "node_role": "turn",
        "node_id": settings.node_id,
        "load": {"credentials_issued": _credentials_issued},
        "security": security_health_snapshot(),
    }


@app.post("/turn/credentials")
def turn_credentials(caller: dict = TurnAuthDep):
    """
    Issues short-lived TURN REST credentials.
    Signed mode requires device JWT (same as home-node).
    """
    global _credentials_issued
    _credentials_issued += 1
    creds = issue_credentials()
    creds["issued_for_user_id"] = caller.get("sub")
    creds["issued_for_device_id"] = caller.get("device_id")
    return creds
