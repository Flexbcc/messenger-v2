import json
import uuid
from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, HTTPException

from app.db import get_conn
from app.fed_security import FederationAuthDep, get_federation_security
from app.schemas import BufferRequest, BufferedEnvelopeResponse, BufferedEnvelopeListResponse
from shared.security.config import BUFFER_MAX_ENVELOPE_BYTES, BUFFER_MAX_ENTRIES_PER_RECIPIENT
from shared.security.envelope_verify import verify_incoming_federation

router = APIRouter()


def _now() -> datetime:
    return datetime.now(timezone.utc)


@router.post("/buffer", response_model=BufferedEnvelopeResponse)
async def buffer_envelope(payload: BufferRequest, _verified: str = FederationAuthDep):
    """Home Node calls this when a recipient device is not reachable directly."""
    envelope_bytes = len(json.dumps(payload.envelope, separators=(",", ":"), ensure_ascii=False))
    if envelope_bytes > BUFFER_MAX_ENVELOPE_BYTES:
        raise HTTPException(status_code=413, detail="Envelope too large")

    fs = get_federation_security()
    await verify_incoming_federation(
        federation=payload.federation,
        envelope=payload.envelope,
        endpoint="/buffer",
        trust_cache=fs.trust_cache,
        nonce_store=fs.nonce_store,
        audit=fs.audit_log,
        expected_origin_node_id=payload.federation.get("origin_node_id") if payload.federation else None,
    )

    entry_id = str(uuid.uuid4())
    now = _now()
    expires_at = now + timedelta(seconds=payload.ttl_seconds)
    with get_conn() as conn:
        count = conn.execute(
            "SELECT COUNT(*) FROM buffered_envelopes WHERE recipient_device_id = ?",
            (payload.recipient_device_id,),
        ).fetchone()[0]
        if count >= BUFFER_MAX_ENTRIES_PER_RECIPIENT:
            raise HTTPException(status_code=429, detail="Buffer queue full for recipient")

        conn.execute(
            """
            INSERT INTO buffered_envelopes (id, recipient_device_id, envelope_json, created_at, expires_at)
            VALUES (?, ?, ?, ?, ?)
            """,
            (entry_id, payload.recipient_device_id, json.dumps(payload.envelope),
             now.isoformat(), expires_at.isoformat()),
        )
        conn.commit()
    return BufferedEnvelopeResponse(
        id=entry_id, recipient_device_id=payload.recipient_device_id,
        envelope=payload.envelope, created_at=now.isoformat(), expires_at=expires_at.isoformat(),
    )


@router.get("/buffer/{recipient_device_id}", response_model=BufferedEnvelopeListResponse)
async def fetch_buffered(recipient_device_id: str, _verified: str = FederationAuthDep):
    """Home Node calls this when the device reconnects, to drain the buffer."""
    now_iso = _now().isoformat()
    with get_conn() as conn:
        conn.execute("DELETE FROM buffered_envelopes WHERE expires_at < ?", (now_iso,))
        conn.commit()
        rows = conn.execute(
            "SELECT * FROM buffered_envelopes WHERE recipient_device_id = ? ORDER BY created_at ASC",
            (recipient_device_id,),
        ).fetchall()
    return BufferedEnvelopeListResponse(
        envelopes=[
            BufferedEnvelopeResponse(
                id=row["id"], recipient_device_id=row["recipient_device_id"],
                envelope=json.loads(row["envelope_json"]),
                created_at=row["created_at"], expires_at=row["expires_at"],
            )
            for row in rows
        ]
    )


@router.delete("/buffer/{entry_id}", status_code=204)
async def ack_delivered(entry_id: str, _verified: str = FederationAuthDep):
    """Home Node calls this once the buffered envelope has been delivered."""
    with get_conn() as conn:
        cur = conn.execute("DELETE FROM buffered_envelopes WHERE id = ?", (entry_id,))
        conn.commit()
        if cur.rowcount == 0:
            raise HTTPException(status_code=404, detail="Not found")
    return None
