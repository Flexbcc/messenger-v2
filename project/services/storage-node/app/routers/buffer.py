import base64
import hashlib
import json
import os
import uuid
from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, HTTPException

from app.db import get_conn
from app.config import settings
from app.fed_security import FederationAuthDep, get_federation_security
from app.schemas import (
    BufferRequest,
    BufferedEnvelopeResponse,
    BufferedEnvelopeListResponse,
    OpaqueMailboxAckRequest,
    OpaqueMailboxCellListResponse,
    OpaqueMailboxCellResponse,
    OpaqueMailboxFetchRequest,
    OpaqueMailboxStoreRequest,
)
from shared.security.config import BUFFER_MAX_ENVELOPE_BYTES, BUFFER_MAX_ENTRIES_PER_RECIPIENT, BUFFER_EVICTION_POLICY
from shared.security.envelope_verify import verify_incoming_federation
from shared.security.mailbox_capability import mailbox_token_bytes
from shared.transport.fixed_cell import CELL_SIZES

router = APIRouter()


def _now() -> datetime:
    return datetime.now(timezone.utc)


@router.post("/buffer", response_model=BufferedEnvelopeResponse)
async def buffer_envelope(payload: BufferRequest, _verified: str = FederationAuthDep):
    """Home Node calls this when a recipient device is not reachable directly."""
    envelope_bytes = len(
        json.dumps(payload.envelope, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    )
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
        expected_recipient_user_id=payload.recipient_device_id,
        expected_ttl_seconds=payload.ttl_seconds,
        expected_routes={"buffer"},
    )

    packet_id = payload.envelope.get("packet_id")
    if packet_id is not None and (not isinstance(packet_id, str) or not packet_id):
        raise HTTPException(status_code=422, detail="envelope.packet_id must be a non-empty string")
    entry_id = str(uuid.uuid4())
    now = _now()
    expires_at = now + timedelta(seconds=payload.ttl_seconds)
    with get_conn() as conn:
        if packet_id:
            existing = conn.execute(
                """SELECT * FROM buffered_envelopes
                   WHERE recipient_device_id = ? AND packet_id = ? LIMIT 1""",
                (payload.recipient_device_id, packet_id),
            ).fetchone()
            if existing:
                return BufferedEnvelopeResponse(
                    id=existing["id"],
                    recipient_device_id=existing["recipient_device_id"],
                    envelope=json.loads(existing["envelope_json"]),
                    created_at=existing["created_at"],
                    expires_at=existing["expires_at"],
                )
        count = conn.execute(
            "SELECT COUNT(*) FROM buffered_envelopes WHERE recipient_device_id = ?",
            (payload.recipient_device_id,),
        ).fetchone()[0]
        if count >= BUFFER_MAX_ENTRIES_PER_RECIPIENT:
            if BUFFER_EVICTION_POLICY == "fifo":
                # Удаляем самое старое сообщение этого получателя
                oldest_id = conn.execute(
                    """SELECT id FROM buffered_envelopes WHERE recipient_device_id = ?
                       ORDER BY created_at ASC LIMIT 1""",
                    (payload.recipient_device_id,),
                ).fetchone()
                if oldest_id:
                    conn.execute(
                        "DELETE FROM buffered_envelopes WHERE id = ?",
                        (oldest_id[0],),
                    )
                    conn.commit()
            else:
                raise HTTPException(status_code=429, detail="Buffer queue full for recipient")

        conn.execute(
            """
            INSERT INTO buffered_envelopes (
                id, recipient_device_id, envelope_json, created_at, expires_at, packet_id
            )
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            (entry_id, payload.recipient_device_id, json.dumps(payload.envelope),
             now.isoformat(), expires_at.isoformat(), packet_id),
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


def _decode_opaque_cell(cell_b64: str) -> bytes:
    try:
        cell = base64.b64decode(
            cell_b64.encode("ascii"), altchars=b"-_", validate=True
        )
    except (UnicodeEncodeError, ValueError) as exc:
        raise HTTPException(status_code=422, detail="invalid opaque cell encoding") from exc
    if len(cell) not in CELL_SIZES:
        raise HTTPException(status_code=422, detail="unsupported fixed cell size")
    return cell


def _validate_mailbox_token(token: str) -> None:
    try:
        mailbox_token_bytes(token)
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc


def _mailbox_hash(token: str) -> str:
    return hashlib.sha256(token.encode("ascii")).hexdigest()


@router.post("/mailbox/store", response_model=OpaqueMailboxCellResponse)
async def store_opaque_mailbox_cell(
    payload: OpaqueMailboxStoreRequest,
    _verified: str = FederationAuthDep,
):
    """Store one endpoint-encrypted fixed cell under an opaque capability."""
    _validate_mailbox_token(payload.mailbox_token)
    mailbox_hash = _mailbox_hash(payload.mailbox_token)
    cell = _decode_opaque_cell(payload.cell_b64)
    cell_hash = hashlib.sha256(cell).hexdigest()
    now = _now()
    expires_at = now + timedelta(seconds=payload.ttl_seconds)
    entry_id = str(uuid.uuid4())
    with get_conn() as conn:
        conn.execute("BEGIN IMMEDIATE")
        conn.execute(
            "DELETE FROM opaque_mailbox_cells WHERE expires_at < ?", (now.isoformat(),)
        )
        existing = conn.execute(
            """SELECT * FROM opaque_mailbox_cells
               WHERE mailbox_hash = ? AND cell_hash = ?""",
            (mailbox_hash, cell_hash),
        ).fetchone()
        if existing:
            conn.commit()
            return OpaqueMailboxCellResponse(
                id=existing["id"],
                cell_b64=existing["cell_b64"],
                cell_size=existing["cell_size"],
                created_at=existing["created_at"],
                expires_at=existing["expires_at"],
            )
        used_bytes = conn.execute(
            "SELECT COALESCE(SUM(cell_size), 0) FROM opaque_mailbox_cells"
        ).fetchone()[0]
        if used_bytes + len(cell) > settings.max_opaque_storage_bytes:
            raise HTTPException(status_code=507, detail="Opaque storage capacity exhausted")
        count = conn.execute(
            "SELECT COUNT(*) FROM opaque_mailbox_cells WHERE mailbox_hash = ?",
            (mailbox_hash,),
        ).fetchone()[0]
        if count >= BUFFER_MAX_ENTRIES_PER_RECIPIENT:
            if BUFFER_EVICTION_POLICY == "fifo":
                conn.execute(
                    """DELETE FROM opaque_mailbox_cells WHERE id = (
                           SELECT id FROM opaque_mailbox_cells
                           WHERE mailbox_hash = ? ORDER BY created_at ASC LIMIT 1
                       )""",
                    (mailbox_hash,),
                )
            else:
                raise HTTPException(status_code=429, detail="Opaque mailbox queue full")
        conn.execute(
            """INSERT INTO opaque_mailbox_cells (
                   id, mailbox_token, mailbox_hash, cell_hash, cell_b64, cell_size,
                   created_at, expires_at
               ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
            (
                entry_id,
                mailbox_hash,
                mailbox_hash,
                cell_hash,
                payload.cell_b64,
                len(cell),
                now.isoformat(),
                expires_at.isoformat(),
            ),
        )
        conn.commit()
    return OpaqueMailboxCellResponse(
        id=entry_id,
        cell_b64=payload.cell_b64,
        cell_size=len(cell),
        created_at=now.isoformat(),
        expires_at=expires_at.isoformat(),
    )


@router.post("/mailbox/fetch", response_model=OpaqueMailboxCellListResponse)
async def fetch_opaque_mailbox_cells(
    payload: OpaqueMailboxFetchRequest,
    _verified: str = FederationAuthDep,
):
    _validate_mailbox_token(payload.mailbox_token)
    if payload.padded:
        if payload.cell_size not in CELL_SIZES:
            raise HTTPException(
                status_code=422,
                detail="padded mailbox poll requires a fixed cell_size class",
            )
        if payload.cell_size * payload.limit > settings.max_padded_poll_bytes:
            raise HTTPException(
                status_code=422,
                detail="padded mailbox poll exceeds response byte budget",
            )
    elif payload.cell_size is not None:
        raise HTTPException(
            status_code=422,
            detail="cell_size is only valid for padded mailbox polling",
        )
    mailbox_hash = _mailbox_hash(payload.mailbox_token)
    now_iso = _now().isoformat()
    with get_conn() as conn:
        conn.execute(
            "DELETE FROM opaque_mailbox_cells WHERE expires_at < ?", (now_iso,)
        )
        conn.commit()
        if payload.padded:
            rows = conn.execute(
                """SELECT * FROM opaque_mailbox_cells
                   WHERE mailbox_hash = ? AND cell_size = ?
                   ORDER BY created_at ASC LIMIT ?""",
                (mailbox_hash, payload.cell_size, payload.limit + 1),
            ).fetchall()
        else:
            rows = conn.execute(
                """SELECT * FROM opaque_mailbox_cells WHERE mailbox_hash = ?
                   ORDER BY created_at ASC LIMIT ?""",
                (mailbox_hash, payload.limit + 1),
            ).fetchall()
    has_more = len(rows) > payload.limit
    rows = rows[: payload.limit]
    cells = [
        OpaqueMailboxCellResponse(
            id=row["id"],
            cell_b64=row["cell_b64"],
            cell_size=row["cell_size"],
            created_at=row["created_at"],
            expires_at=row["expires_at"],
        )
        for row in rows
    ]
    if payload.padded:
        dummy_now = _now()
        while len(cells) < payload.limit:
            dummy = os.urandom(payload.cell_size)
            cells.append(
                OpaqueMailboxCellResponse(
                    id=str(uuid.uuid4()),
                    cell_b64=base64.urlsafe_b64encode(dummy).decode("ascii"),
                    cell_size=payload.cell_size,
                    created_at=dummy_now.isoformat(),
                    expires_at=(dummy_now + timedelta(minutes=1)).isoformat(),
                )
            )
        # The endpoint drains another fixed poll after authenticating/ACKing
        # real cells; exposing queue continuation changes response length.
        has_more = False
    return OpaqueMailboxCellListResponse(
        cells=cells,
        has_more=has_more,
    )


@router.post("/mailbox/ack", status_code=204)
async def ack_opaque_mailbox_cell(
    payload: OpaqueMailboxAckRequest,
    _verified: str = FederationAuthDep,
):
    _validate_mailbox_token(payload.mailbox_token)
    mailbox_hash = _mailbox_hash(payload.mailbox_token)
    with get_conn() as conn:
        cursor = conn.execute(
            "DELETE FROM opaque_mailbox_cells WHERE id = ? AND mailbox_hash = ?",
            (payload.entry_id, mailbox_hash),
        )
        conn.commit()
    if cursor.rowcount == 0:
        raise HTTPException(status_code=404, detail="Not found")
    return None
