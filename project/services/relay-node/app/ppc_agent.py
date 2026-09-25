"""PPC agent tunnel — storage-app behind NAT connects outbound; peers invoke HTTP via relay."""
import asyncio
import base64
import binascii
import hashlib
import logging
import re
import time
import uuid
from dataclasses import dataclass, field

from fastapi import APIRouter, HTTPException, WebSocket, WebSocketDisconnect

from app.fed_security import FederationAuthDep, get_federation_security
from shared.security.federation_auth import verify_federation_headers
from shared.security.keys import verify_message

logger = logging.getLogger(__name__)

INVOKE_TIMEOUT_SECONDS = 30.0
AGENT_HANDSHAKE_TIMEOUT_SECONDS = 10.0
AGENT_IDLE_TIMEOUT_SECONDS = 90.0
MAX_AGENTS = 1000
MAX_PENDING_PER_AGENT = 128
MAX_PPC_BODY_BYTES = 64 * 1024 * 1024
MAX_RELAY_BODY_B64_CHARS = ((MAX_PPC_BODY_BYTES + 2) // 3) * 4
MAX_RELAY_HEADERS = 64
_NODE_ID_RE = re.compile(r"^[A-Za-z0-9._:-]{1,256}$")
_ALLOWED_PPC_HEADERS = {
    "content-type",
    "range",
    "x-ppc-node-id",
    "x-ppc-pubkey",
    "x-ppc-timestamp",
    "x-ppc-signature",
}

router = APIRouter(prefix="/relay/ppc", tags=["ppc-agent"])


@dataclass
class AgentSession:
    node_id: str
    storage_pubkey: str
    websocket: WebSocket
    pending: dict[str, asyncio.Future] = field(default_factory=dict)


_agents: dict[str, AgentSession] = {}


def _valid_storage_pubkey(value: object) -> bool:
    if not isinstance(value, str) or not value.startswith("ed25519:"):
        return False
    try:
        decoded = base64.b64decode(
            value.removeprefix("ed25519:"), altchars=b"-_", validate=True
        )
    except (ValueError, TypeError, binascii.Error):
        return False
    return (
        len(decoded) == 32
        and base64.b64encode(decoded).decode("ascii")
        == value.removeprefix("ed25519:")
    )


def _valid_agent_handshake(raw: object, authenticated_node_id: str) -> tuple[str, str] | None:
    if not isinstance(raw, dict) or set(raw) != {
        "node_id",
        "storage_pubkey",
        "timestamp",
        "signature",
    }:
        return None
    node_id = raw.get("node_id")
    storage_pubkey = raw.get("storage_pubkey")
    timestamp = raw.get("timestamp")
    signature = raw.get("signature")
    if (
        node_id != authenticated_node_id
        or not isinstance(node_id, str)
        or _NODE_ID_RE.fullmatch(node_id) is None
        or not _valid_storage_pubkey(storage_pubkey)
        or not isinstance(timestamp, int)
        or isinstance(timestamp, bool)
        or abs(int(time.time()) - timestamp) > 120
        or not isinstance(signature, str)
    ):
        return None
    canonical = f"RELAY_HANDSHAKE\n{node_id}\n{timestamp}".encode("utf-8")
    digest = hashlib.sha256(canonical).hexdigest()
    message = f"RELAY_HANDSHAKE\n{node_id}\n{timestamp}\n{digest}".encode("utf-8")
    public_key = storage_pubkey.removeprefix("ed25519:")
    if not verify_message(public_key, message, signature):
        return None
    return node_id, storage_pubkey


def _validated_invoke_payload(payload: object) -> dict:
    if not isinstance(payload, dict):
        raise HTTPException(status_code=400, detail="payload must be an object")
    method = payload.get("method")
    path = payload.get("path")
    headers = payload.get("headers") or {}
    body_b64 = payload.get("body_b64") or ""
    if method not in {"GET", "POST", "PUT", "PATCH", "DELETE", "HEAD"}:
        raise HTTPException(status_code=400, detail="invalid method")
    if (
        not isinstance(path, str)
        or not path.startswith("/ppc/")
        or path.startswith("//")
        or len(path) > 2048
        or any(ord(character) < 32 for character in path)
    ):
        raise HTTPException(status_code=400, detail="invalid path")
    if not isinstance(headers, dict) or len(headers) > MAX_RELAY_HEADERS:
        raise HTTPException(status_code=400, detail="invalid headers")
    if any(
        not isinstance(key, str)
        or not isinstance(value, str)
        or not key
        or len(key) > 128
        or len(value) > 8192
        or any(ord(character) < 32 for character in key + value)
        or key.lower() not in _ALLOWED_PPC_HEADERS
        for key, value in headers.items()
    ):
        raise HTTPException(status_code=400, detail="invalid headers")
    if not _valid_body_b64(body_b64):
        raise HTTPException(status_code=413, detail="relay body is too large")
    return {"method": method, "path": path, "headers": headers, "body_b64": body_b64}


def _validated_agent_response(response: object) -> dict:
    if not isinstance(response, dict):
        raise HTTPException(status_code=502, detail="invalid PPC agent response")
    status = response.get("status")
    headers = response.get("headers") or {}
    body_b64 = response.get("body_b64") or ""
    if not isinstance(status, int) or isinstance(status, bool) or not 100 <= status <= 599:
        raise HTTPException(status_code=502, detail="invalid PPC agent status")
    if not isinstance(headers, dict) or len(headers) > MAX_RELAY_HEADERS:
        raise HTTPException(status_code=502, detail="invalid PPC agent headers")
    if any(
        not isinstance(key, str)
        or not isinstance(value, str)
        or not key
        or len(key) > 128
        or len(value) > 8192
        or any(ord(character) < 32 for character in key + value)
        for key, value in headers.items()
    ):
        raise HTTPException(status_code=502, detail="invalid PPC agent headers")
    if not _valid_body_b64(body_b64):
        raise HTTPException(status_code=502, detail="invalid PPC agent body")
    return {"status": status, "headers": headers, "body_b64": body_b64}


def _valid_body_b64(value: object) -> bool:
    if not isinstance(value, str) or len(value) > MAX_RELAY_BODY_B64_CHARS:
        return False
    if value == "":
        return True
    try:
        decoded = base64.b64decode(value, validate=True)
    except (ValueError, binascii.Error):
        return False
    return len(decoded) <= MAX_PPC_BODY_BYTES and base64.b64encode(decoded).decode("ascii") == value


@router.websocket("/agent")
async def ppc_agent_websocket(websocket: WebSocket):
    node_id: str | None = None
    session: AgentSession | None = None
    try:
        fs = get_federation_security()
        try:
            authenticated_node_id = await verify_federation_headers(
                websocket.headers,
                method="GET",
                path="/relay/ppc/agent",
                body=b"",
                trust_cache=fs.trust_cache,
                nonce_store=fs.nonce_store,
            )
            if not await fs.trust_cache.has_capability(
                authenticated_node_id, "storage"
            ):
                raise HTTPException(
                    status_code=403, detail="storage capability is required"
                )
        except HTTPException as exc:
            await websocket.close(
                code=4400 + min(exc.status_code, 99), reason="authentication failed"
            )
            return

        if authenticated_node_id not in _agents and len(_agents) >= MAX_AGENTS:
            await websocket.close(code=4429, reason="agent capacity reached")
            return

        await websocket.accept()
        raw = await asyncio.wait_for(
            websocket.receive_json(), timeout=AGENT_HANDSHAKE_TIMEOUT_SECONDS
        )
        handshake = _valid_agent_handshake(raw, authenticated_node_id)
        if handshake is None:
            await websocket.close(code=4403, reason="invalid agent identity")
            return
        node_id, storage_pubkey = handshake
        trusted_signing_key = await fs.trust_cache.signing_public_key(node_id)
        if trusted_signing_key != storage_pubkey.removeprefix("ed25519:"):
            await websocket.close(code=4403, reason="agent key mismatch")
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
            msg = await asyncio.wait_for(
                websocket.receive_json(), timeout=AGENT_IDLE_TIMEOUT_SECONDS
            )
            if not isinstance(msg, dict):
                await websocket.close(code=4400, reason="invalid agent response")
                break
            req_id = msg.get("id")
            if isinstance(req_id, str) and req_id in session.pending:
                fut = session.pending.pop(req_id)
                if not fut.done():
                    fut.set_result(msg)
    except asyncio.TimeoutError:
        await websocket.close(code=4408, reason="agent timeout")
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
    if not await get_federation_security().trust_cache.has_capability(
        _verified, "home"
    ):
        raise HTTPException(status_code=403, detail="home capability is required")
    if _NODE_ID_RE.fullmatch(storage_node_id) is None:
        raise HTTPException(status_code=400, detail="invalid storage node id")
    validated = _validated_invoke_payload(payload)
    session = _agents.get(storage_node_id)
    if session is None:
        raise HTTPException(status_code=502, detail="PPC agent offline")
    if len(session.pending) >= MAX_PENDING_PER_AGENT:
        raise HTTPException(status_code=429, detail="PPC agent is busy")

    req_id = str(uuid.uuid4())
    loop = asyncio.get_running_loop()
    fut: asyncio.Future = loop.create_future()
    session.pending[req_id] = fut

    invoke_msg = {
        "type": "invoke",
        "id": req_id,
        **validated,
    }
    try:
        await session.websocket.send_json(invoke_msg)
    except Exception as e:
        session.pending.pop(req_id, None)
        logger.warning("PPC agent send failed node_id=%s", storage_node_id)
        raise HTTPException(status_code=502, detail="PPC agent unreachable") from e

    try:
        response = await asyncio.wait_for(fut, timeout=INVOKE_TIMEOUT_SECONDS)
    except asyncio.TimeoutError:
        session.pending.pop(req_id, None)
        raise HTTPException(status_code=504, detail="PPC invoke timed out")
    except ConnectionError as e:
        session.pending.pop(req_id, None)
        raise HTTPException(status_code=502, detail="PPC agent disconnected") from e

    return _validated_agent_response(response)
