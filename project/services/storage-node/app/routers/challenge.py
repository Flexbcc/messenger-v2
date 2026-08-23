"""Bounded opaque STORE→GET primitive for synthetic Storage challenges."""

import base64
import hashlib
import secrets
from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field

from app.db import get_conn
from app.fed_security import ChallengeObserverAuthDep


router = APIRouter()
CELL_BYTES = 4096
MAX_ACTIVE_CELLS = 1000
MAX_ACTIVE_CELLS_PER_OBSERVER = 4
CELL_TTL = timedelta(minutes=5)


class ChallengeStoreRequest(BaseModel):
    cell_b64: str = Field(min_length=5464, max_length=5464)
    expected_hash: str = Field(min_length=64, max_length=64)


def _iso(value: datetime) -> str:
    return value.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


@router.post("/internal/challenge/storage/store")
def challenge_store(
    payload: ChallengeStoreRequest,
    observer: str = ChallengeObserverAuthDep,
):
    try:
        cell = base64.b64decode(payload.cell_b64, altchars=b"-_", validate=True)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail="invalid challenge cell") from exc
    digest = hashlib.sha256(cell).hexdigest()
    if len(cell) != CELL_BYTES or not secrets.compare_digest(digest, payload.expected_hash):
        raise HTTPException(status_code=400, detail="challenge cell hash mismatch")
    now = datetime.now(timezone.utc)
    token = secrets.token_urlsafe(32)
    with get_conn() as conn:
        conn.execute(
            "DELETE FROM synthetic_challenge_cells WHERE expires_at < ?", (_iso(now),)
        )
        active = conn.execute(
            "SELECT COUNT(*) FROM synthetic_challenge_cells"
        ).fetchone()[0]
        if active >= MAX_ACTIVE_CELLS:
            raise HTTPException(status_code=429, detail="challenge storage is full")
        observer_active = conn.execute(
            """SELECT COUNT(*) FROM synthetic_challenge_cells
               WHERE observer_node_id = ?""",
            (observer,),
        ).fetchone()[0]
        if observer_active >= MAX_ACTIVE_CELLS_PER_OBSERVER:
            raise HTTPException(status_code=429, detail="observer challenge quota exceeded")
        conn.execute(
            """INSERT INTO synthetic_challenge_cells
               (token, observer_node_id, cell_hash, cell_b64, expires_at)
               VALUES (?, ?, ?, ?, ?)""",
            (token, observer, digest, payload.cell_b64, _iso(now + CELL_TTL)),
        )
        conn.commit()
    return {"token": token, "cell_hash": digest, "expires_at": _iso(now + CELL_TTL)}


@router.get("/internal/challenge/storage/get/{token}")
def challenge_get(token: str, observer: str = ChallengeObserverAuthDep):
    if not 40 <= len(token) <= 64:
        raise HTTPException(status_code=400, detail="invalid challenge token")
    now = datetime.now(timezone.utc)
    with get_conn() as conn:
        row = conn.execute(
            """SELECT cell_hash, cell_b64, expires_at
               FROM synthetic_challenge_cells
               WHERE token = ? AND observer_node_id = ?""",
            (token, observer),
        ).fetchone()
        if row is None or row["expires_at"] < _iso(now):
            raise HTTPException(status_code=404, detail="challenge cell unavailable")
        conn.execute("DELETE FROM synthetic_challenge_cells WHERE token = ?", (token,))
        conn.commit()
    return {"cell_hash": row["cell_hash"], "cell_b64": row["cell_b64"]}
