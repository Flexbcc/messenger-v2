"""PPC agent tunnel — storage-app behind NAT connects outbound; peers invoke HTTP via relay."""
import asyncio
import logging
import uuid
from dataclasses import dataclass, field

from fastapi import APIRouter, HTTPException, WebSocket, WebSocketDisconnect

from app.fed_security import FederationAuthDep

logger = logging.getLogger(__name__)

INVOKE_TIMEOUT_SECONDS = 30.0

router = APIRouter(prefix="/relay/ppc", tags=["ppc-agent"])


@dataclass
class AgentSession:
    node_id: str
    storage_pubkey: str
    websocket: WebSocket
    pending: dict[str, asyncio.Future] = field(default_factory=dict)


_agents: dict[str, AgentSession] = {}


@router.websocket("/agent")
async def ppc_agent_websocket(websocket: WebSocket):
    await websocket.accept()
    node_id: str | None = None
    session: AgentSession | None = None
    try:
        raw = await websocket.receive_json()
        node_id = raw.get("node_id")
        storage_pubkey = raw.get("storage_pubkey")
        if not node_id or not storage_pubkey:
            await websocket.close(code=4400, reason="node_id and storage_pubkey required")
            return

        existing = _agents.get(node_id)
        if existing is not None and existing.websocket is not websocket:
            for fut in existing.pending.values():
                if not fut.done():
                    fut.set_exception(ConnectionError("agent reconnected"))
            existing.pending.clear()
            try:
                await existing.websocket.close(code=4410, reason="superseded")
            except Exception:
                pass

        session = AgentSession(
            node_id=node_id,
            storage_pubkey=storage_pubkey,
            websocket=websocket,
        )
        _agents[node_id] = session
        logger.info("PPC agent registered: node_id=%s", node_id)

        while True:
            msg = await websocket.receive_json()
            req_id = msg.get("id")
            if req_id and req_id in session.pending:
                fut = session.pending.pop(req_id)
                if not fut.done():
                    fut.set_result(msg)
    except WebSocketDisconnect:
        pass
    except Exception as e:
        logger.warning("PPC agent session error node_id=%s: %s", node_id, e)
    finally:
        if node_id and session and _agents.get(node_id) is session:
            del _agents[node_id]
            for fut in session.pending.values():
                if not fut.done():
                    fut.set_exception(ConnectionError("agent disconnected"))
            session.pending.clear()
            logger.info("PPC agent disconnected: node_id=%s", node_id)


@router.post("/{storage_node_id}/invoke")
async def invoke_ppc(
    storage_node_id: str,
    payload: dict,
    _verified: str = FederationAuthDep,
):
    session = _agents.get(storage_node_id)
    if session is None:
        raise HTTPException(status_code=502, detail="PPC agent offline")

    for key in ("method", "path"):
        if key not in payload:
            raise HTTPException(status_code=400, detail=f"{key} is required")

    req_id = str(uuid.uuid4())
    loop = asyncio.get_running_loop()
    fut: asyncio.Future = loop.create_future()
    session.pending[req_id] = fut

    invoke_msg = {
        "type": "invoke",
        "id": req_id,
        "method": payload["method"],
        "path": payload["path"],
        "headers": payload.get("headers") or {},
        "body_b64": payload.get("body_b64") or "",
    }
    try:
        await session.websocket.send_json(invoke_msg)
    except Exception as e:
        session.pending.pop(req_id, None)
        raise HTTPException(status_code=502, detail=f"PPC agent unreachable: {e}") from e

    try:
        response = await asyncio.wait_for(fut, timeout=INVOKE_TIMEOUT_SECONDS)
    except asyncio.TimeoutError:
        session.pending.pop(req_id, None)
        raise HTTPException(status_code=504, detail="PPC invoke timed out")
    except ConnectionError as e:
        raise HTTPException(status_code=502, detail=str(e)) from e

    return {
        "status": response.get("status", 502),
        "headers": response.get("headers") or {},
        "body_b64": response.get("body_b64") or "",
    }
