"""One-time cluster join invites (QR / deep link)."""
from __future__ import annotations

import os
import secrets
import sqlite3
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from typing import Optional

from app.config import settings

DB_PATH = settings.invite_db_path
DEFAULT_TTL = settings.invite_ttl_seconds


def _utcnow() -> datetime:
    return datetime.now(timezone.utc)


def _iso(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).isoformat()


@contextmanager
def _conn():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    try:
        yield conn
    finally:
        conn.close()


def init_db() -> None:
    os.makedirs(os.path.dirname(DB_PATH) or ".", exist_ok=True)
    with _conn() as conn:
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS invites (
                token TEXT PRIMARY KEY,
                cluster_id TEXT NOT NULL,
                label TEXT,
                created_at TEXT NOT NULL,
                expires_at TEXT NOT NULL,
                used_at TEXT,
                created_by TEXT
            )
            """
        )
        conn.execute("CREATE INDEX IF NOT EXISTS idx_invites_expires ON invites(expires_at)")
        conn.commit()


def create_invite(
    *,
    cluster_id: str,
    ttl_seconds: int = DEFAULT_TTL,
    label: Optional[str] = None,
    created_by: Optional[str] = None,
) -> dict:
    if not 30 <= ttl_seconds <= 86400:
        raise ValueError("ttl_seconds must be between 30 and 86400")
    token = secrets.token_urlsafe(32)
    now = _utcnow()
    expires = now + timedelta(seconds=ttl_seconds)
    with _conn() as conn:
        conn.execute(
            """
            INSERT INTO invites (token, cluster_id, label, created_at, expires_at, created_by)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            (token, cluster_id, label, _iso(now), _iso(expires), created_by),
        )
        conn.commit()
    return {
        "token": token,
        "cluster_id": cluster_id,
        "label": label,
        "expires_at": _iso(expires),
    }


def _row_valid(row: sqlite3.Row) -> bool:
    if row["used_at"]:
        return False
    try:
        expires = datetime.fromisoformat(row["expires_at"])
    except ValueError:
        return False
    return expires > _utcnow()


def get_invite(token: str) -> Optional[sqlite3.Row]:
    with _conn() as conn:
        row = conn.execute("SELECT * FROM invites WHERE token = ?", (token,)).fetchone()
    if not row or not _row_valid(row):
        return None
    return row


def redeem_invite(token: str) -> Optional[dict]:
    now = _iso(_utcnow())
    with _conn() as conn:
        row = conn.execute("SELECT * FROM invites WHERE token = ?", (token,)).fetchone()
        if not row or not _row_valid(row):
            return None
        conn.execute("UPDATE invites SET used_at = ? WHERE token = ?", (now, token))
        conn.commit()
        return {
            "cluster_id": row["cluster_id"],
            "label": row["label"],
        }


def peek_invite(token: str) -> Optional[dict]:
    row = get_invite(token)
    if not row:
        return None
    return {"cluster_id": row["cluster_id"], "label": row["label"], "expires_at": row["expires_at"]}


def purge_expired() -> int:
    cutoff = _iso(_utcnow())
    with _conn() as conn:
        cur = conn.execute(
            "DELETE FROM invites WHERE expires_at < ? OR used_at IS NOT NULL",
            (cutoff,),
        )
        conn.commit()
        return cur.rowcount
