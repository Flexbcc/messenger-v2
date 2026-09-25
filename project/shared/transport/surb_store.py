"""Endpoint-side bounded one-time store for opaque Sphinx reply blocks."""

from __future__ import annotations

import hashlib
import sqlite3
import time
from pathlib import Path


class SurbStore:
    def __init__(self, path: str, *, max_records: int = 100_000) -> None:
        if not path or not 1 <= max_records <= 1_000_000:
            raise ValueError("invalid SURB store configuration")
        self.path = path
        self.max_records = max_records
        Path(path).parent.mkdir(parents=True, exist_ok=True)
        with self._connect() as connection:
            connection.execute(
                """CREATE TABLE IF NOT EXISTS reply_blocks (
                       surb_id TEXT PRIMARY KEY,
                       surb BLOB NOT NULL,
                       expires_at INTEGER NOT NULL,
                       consumed INTEGER NOT NULL DEFAULT 0
                   )"""
            )
            connection.execute(
                "CREATE INDEX IF NOT EXISTS idx_reply_blocks_expiry ON reply_blocks(expires_at)"
            )
        try:
            Path(path).chmod(0o600)
        except OSError:
            pass

    def _connect(self) -> sqlite3.Connection:
        connection = sqlite3.connect(self.path, timeout=5, isolation_level=None)
        connection.execute("PRAGMA journal_mode=WAL")
        connection.execute("PRAGMA busy_timeout=5000")
        return connection

    @staticmethod
    def identifier(surb: bytes) -> str:
        return hashlib.sha256(b"OUO/SURB_ID/v1\x00" + surb).hexdigest()

    def add(self, surb: bytes, *, expires_at_unix: int) -> str:
        if not isinstance(surb, bytes) or not 1 <= len(surb) <= 256 * 1024:
            raise ValueError("invalid SURB")
        now = int(time.time())
        if not now < expires_at_unix <= now + 2_592_000:
            raise ValueError("invalid SURB expiry")
        surb_id = self.identifier(surb)
        with self._connect() as connection:
            connection.execute("BEGIN IMMEDIATE")
            connection.execute("DELETE FROM reply_blocks WHERE expires_at < ?", (now,))
            existing = connection.execute(
                "SELECT 1 FROM reply_blocks WHERE surb_id = ?", (surb_id,)
            ).fetchone()
            if existing is not None:
                connection.commit()
                return surb_id
            count = connection.execute("SELECT COUNT(*) FROM reply_blocks").fetchone()[0]
            if count >= self.max_records:
                connection.rollback()
                raise RuntimeError("SURB store capacity exhausted")
            connection.execute(
                """INSERT INTO reply_blocks(surb_id, surb, expires_at, consumed)
                   VALUES (?, ?, ?, 0)
                   ON CONFLICT(surb_id) DO NOTHING""",
                (surb_id, surb, expires_at_unix),
            )
            connection.commit()
        return surb_id

    def consume(self, surb_id: str) -> bytes | None:
        if not isinstance(surb_id, str) or len(surb_id) != 64:
            raise ValueError("invalid SURB identifier")
        now = int(time.time())
        with self._connect() as connection:
            connection.execute("BEGIN IMMEDIATE")
            row = connection.execute(
                """SELECT surb FROM reply_blocks
                   WHERE surb_id = ? AND consumed = 0 AND expires_at >= ?""",
                (surb_id, now),
            ).fetchone()
            if row is None:
                connection.rollback()
                return None
            connection.execute(
                "UPDATE reply_blocks SET consumed = 1, surb = X'' WHERE surb_id = ?",
                (surb_id,),
            )
            connection.commit()
            return bytes(row[0])
