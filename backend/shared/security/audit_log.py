"""Audit log for federation events — metadata only, no plaintext (Phase B4)."""
import sqlite3
import time
import uuid
from contextlib import contextmanager
from typing import Optional


class FederationAuditLog:
    def __init__(self, db_path: Optional[str] = None):
        self._db_path = db_path
        self._memory: list[dict] = []
        if db_path:
            self._init_db()

    def _init_db(self) -> None:
        with self._conn() as conn:
            conn.execute(
                """
                CREATE TABLE IF NOT EXISTS federation_audit (
                    id TEXT PRIMARY KEY,
                    ts REAL NOT NULL,
                    origin_node_id TEXT NOT NULL,
                    endpoint TEXT NOT NULL,
                    packet_id TEXT,
                    action TEXT NOT NULL,
                    result TEXT NOT NULL,
                    detail TEXT
                )
                """
            )
            conn.execute(
                "CREATE INDEX IF NOT EXISTS idx_federation_audit_ts ON federation_audit(ts)"
            )
            conn.commit()

    @contextmanager
    def _conn(self):
        conn = sqlite3.connect(self._db_path)
        try:
            yield conn
        finally:
            conn.close()

    def record(
        self,
        *,
        origin_node_id: str,
        endpoint: str,
        action: str,
        result: str,
        packet_id: str = "",
        detail: str = "",
    ) -> None:
        entry = {
            "id": str(uuid.uuid4()),
            "ts": time.time(),
            "origin_node_id": origin_node_id,
            "endpoint": endpoint,
            "packet_id": packet_id,
            "action": action,
            "result": result,
            "detail": detail[:500],
        }
        if self._db_path:
            with self._conn() as conn:
                conn.execute(
                    """
                    INSERT INTO federation_audit
                    (id, ts, origin_node_id, endpoint, packet_id, action, result, detail)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    (
                        entry["id"],
                        entry["ts"],
                        entry["origin_node_id"],
                        entry["endpoint"],
                        entry["packet_id"],
                        entry["action"],
                        entry["result"],
                        entry["detail"],
                    ),
                )
                conn.commit()
        else:
            self._memory.append(entry)
            if len(self._memory) > 1000:
                self._memory = self._memory[-500:]

    def recent(self, limit: int = 20) -> list[dict]:
        if self._db_path:
            with self._conn() as conn:
                rows = conn.execute(
                    """
                    SELECT origin_node_id, endpoint, packet_id, action, result, detail, ts
                    FROM federation_audit ORDER BY ts DESC LIMIT ?
                    """,
                    (limit,),
                ).fetchall()
            return [
                {
                    "origin_node_id": r[0],
                    "endpoint": r[1],
                    "packet_id": r[2],
                    "action": r[3],
                    "result": r[4],
                    "detail": r[5],
                    "ts": r[6],
                }
                for r in rows
            ]
        return list(reversed(self._memory[-limit:]))
