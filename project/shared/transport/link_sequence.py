"""Persistent per-connection binary batch replay protection."""

import sqlite3
import time
from pathlib import Path


class LinkSequenceStore:
    def __init__(self, path: str, *, ttl_seconds: int = 86400, max_records: int = 100000):
        if ttl_seconds < 60 or max_records < 1:
            raise ValueError("invalid LinkSequenceStore bounds")
        self.path = path
        self.ttl_seconds = ttl_seconds
        self.max_records = max_records
        Path(path).parent.mkdir(parents=True, exist_ok=True)
        with self._connect() as conn:
            conn.execute(
                """CREATE TABLE IF NOT EXISTS link_sequences (
                       peer_node_id TEXT NOT NULL,
                       connection_id TEXT NOT NULL,
                       highest_sequence INTEGER NOT NULL,
                       updated_at INTEGER NOT NULL DEFAULT 0,
                       PRIMARY KEY(peer_node_id, connection_id)
                   )"""
            )
            columns = {row[1] for row in conn.execute("PRAGMA table_info(link_sequences)")}
            if "updated_at" not in columns:
                conn.execute(
                    "ALTER TABLE link_sequences ADD COLUMN updated_at INTEGER NOT NULL DEFAULT 0"
                )
            conn.execute(
                "CREATE INDEX IF NOT EXISTS idx_link_sequences_updated ON link_sequences(updated_at)"
            )
            conn.commit()

    def _connect(self):
        return sqlite3.connect(self.path)

    def accept(self, *, peer_node_id: str, connection_id: str, sequence: int) -> bool:
        if not isinstance(peer_node_id, str) or not 1 <= len(peer_node_id) <= 256:
            raise ValueError("invalid peer_node_id")
        if not isinstance(connection_id, str) or not 1 <= len(connection_id) <= 128:
            raise ValueError("invalid connection_id")
        # SQLite INTEGER is signed 64-bit even though the wire field is u64.
        if not isinstance(sequence, int) or isinstance(sequence, bool) or not 0 <= sequence < 2**63:
            raise ValueError("sequence is outside persistent range")
        now = int(time.time())
        with self._connect() as conn:
            conn.execute("BEGIN IMMEDIATE")
            conn.execute(
                "DELETE FROM link_sequences WHERE updated_at < ?",
                (now - self.ttl_seconds,),
            )
            row = conn.execute(
                "SELECT highest_sequence FROM link_sequences WHERE peer_node_id = ? AND connection_id = ?",
                (peer_node_id, connection_id),
            ).fetchone()
            expected = 1 if row is None else row[0] + 1
            if sequence != expected:
                conn.rollback()
                return False
            conn.execute(
                """INSERT INTO link_sequences (
                       peer_node_id, connection_id, highest_sequence, updated_at
                   ) VALUES (?, ?, ?, ?)
                   ON CONFLICT(peer_node_id, connection_id) DO UPDATE SET
                       highest_sequence=excluded.highest_sequence,
                       updated_at=excluded.updated_at""",
                (peer_node_id, connection_id, sequence, now),
            )
            count = conn.execute("SELECT COUNT(*) FROM link_sequences").fetchone()[0]
            overflow = count - self.max_records
            if overflow > 0:
                conn.execute(
                    """DELETE FROM link_sequences WHERE rowid IN (
                           SELECT rowid FROM link_sequences
                           ORDER BY updated_at ASC, rowid ASC LIMIT ?
                       )""",
                    (overflow,),
                )
            conn.commit()
        return True
