"""Persistent quota and revocation state for accepted Contact Capabilities."""

from __future__ import annotations

import hashlib
import os
import sqlite3
from datetime import datetime, timezone
from pathlib import Path


class ContactCapabilityStore:
    def __init__(self, path: str, *, max_records: int = 1_000_000) -> None:
        if not path or not 1 <= max_records <= 10_000_000:
            raise ValueError("invalid Contact Capability store configuration")
        self.path = path
        self.max_records = max_records
        Path(path).parent.mkdir(parents=True, exist_ok=True)
        with self._connect() as connection:
            connection.execute(
                """CREATE TABLE IF NOT EXISTS contact_capability_usage (
                       capability_hash TEXT PRIMARY KEY,
                       used_count INTEGER NOT NULL,
                       max_requests INTEGER NOT NULL,
                       expires_unix INTEGER NOT NULL,
                       revoked INTEGER NOT NULL DEFAULT 0,
                       updated_at TEXT NOT NULL
                   )"""
            )
            connection.execute(
                """CREATE INDEX IF NOT EXISTS idx_contact_capability_expiry
                   ON contact_capability_usage(expires_unix)"""
            )
        os.chmod(path, 0o600)

    def _connect(self) -> sqlite3.Connection:
        connection = sqlite3.connect(self.path, timeout=5, isolation_level=None)
        connection.execute("PRAGMA journal_mode=WAL")
        connection.execute("PRAGMA busy_timeout=5000")
        return connection

    @staticmethod
    def _hash(capability_id: str) -> str:
        return hashlib.sha256(
            b"OUO/CONTACT_CAPABILITY_ID/v1\x00" + capability_id.encode("ascii")
        ).hexdigest()

    def consume(
        self, *, capability_id: str, max_requests: int, expires_at: str
    ) -> bool:
        digest = self._hash(capability_id)
        current = datetime.now(timezone.utc)
        now = current.isoformat()
        expiry = datetime.fromisoformat(
            expires_at[:-1] + "+00:00" if expires_at.endswith("Z") else expires_at
        )
        if expiry.tzinfo is None or expiry.utcoffset() is None or expiry <= current:
            return False
        expires_unix = int(expiry.timestamp())
        with self._connect() as connection:
            connection.execute("BEGIN IMMEDIATE")
            connection.execute(
                "DELETE FROM contact_capability_usage WHERE expires_unix < ?",
                (int(current.timestamp()),),
            )
            row = connection.execute(
                """SELECT used_count, max_requests, expires_unix, revoked
                   FROM contact_capability_usage WHERE capability_hash = ?""",
                (digest,),
            ).fetchone()
            if row:
                used, stored_max, stored_expiry, revoked = row
                if revoked or stored_max != max_requests or stored_expiry != expires_unix:
                    connection.rollback()
                    return False
                if used >= max_requests:
                    connection.rollback()
                    return False
                connection.execute(
                    """UPDATE contact_capability_usage
                       SET used_count = used_count + 1, updated_at = ?
                       WHERE capability_hash = ?""",
                    (now, digest),
                )
                connection.commit()
                return True
            count = connection.execute(
                "SELECT COUNT(*) FROM contact_capability_usage"
            ).fetchone()[0]
            if count >= self.max_records:
                connection.rollback()
                return False
            connection.execute(
                """INSERT INTO contact_capability_usage
                   (capability_hash, used_count, max_requests, expires_unix, revoked, updated_at)
                   VALUES (?, 1, ?, ?, 0, ?)""",
                (digest, max_requests, expires_unix, now),
            )
            connection.commit()
            return True

    def revoke(self, capability_id: str, *, expires_at: str) -> None:
        digest = self._hash(capability_id)
        now = datetime.now(timezone.utc).isoformat()
        expiry = datetime.fromisoformat(
            expires_at[:-1] + "+00:00" if expires_at.endswith("Z") else expires_at
        )
        if expiry.tzinfo is None or expiry.utcoffset() is None:
            raise ValueError("revocation expiry must be timezone-aware")
        with self._connect() as connection:
            connection.execute(
                """INSERT INTO contact_capability_usage
                   (capability_hash, used_count, max_requests, expires_unix, revoked, updated_at)
                   VALUES (?, 0, 1, ?, 1, ?)
                   ON CONFLICT(capability_hash) DO UPDATE SET
                       revoked = 1, updated_at = excluded.updated_at""",
                (digest, int(expiry.timestamp()), now),
            )
