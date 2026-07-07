import sqlite3
import time
from contextlib import contextmanager
from typing import Optional


class NonceStore:
    def __init__(self, db_path: Optional[str] = None):
        self._db_path = db_path
        self._memory: dict[str, float] = {}
        if db_path:
            self._init_db()

    def _init_db(self) -> None:
        with self._conn() as conn:
            conn.execute(
                """
                CREATE TABLE IF NOT EXISTS used_nonces (
                    nonce TEXT PRIMARY KEY,
                    origin_node_id TEXT NOT NULL,
                    expires_at REAL NOT NULL
                )
                """
            )
            conn.execute(
                "CREATE INDEX IF NOT EXISTS idx_used_nonces_expires ON used_nonces(expires_at)"
            )
            conn.commit()

    @contextmanager
    def _conn(self):
        conn = sqlite3.connect(self._db_path)
        try:
            yield conn
        finally:
            conn.close()

    def _purge_expired(self) -> None:
        now = time.time()
        if self._db_path:
            with self._conn() as conn:
                conn.execute("DELETE FROM used_nonces WHERE expires_at < ?", (now,))
                conn.commit()
        else:
            expired = [k for k, exp in self._memory.items() if exp < now]
            for k in expired:
                del self._memory[k]

    def consume(self, nonce: str, origin_node_id: str, ttl_seconds: int) -> bool:
        """Returns True if nonce is new (accepted), False if replay."""
        self._purge_expired()
        expires_at = time.time() + ttl_seconds
        if self._db_path:
            with self._conn() as conn:
                try:
                    conn.execute(
                        "INSERT INTO used_nonces (nonce, origin_node_id, expires_at) VALUES (?, ?, ?)",
                        (nonce, origin_node_id, expires_at),
                    )
                    conn.commit()
                    return True
                except sqlite3.IntegrityError:
                    return False
        if nonce in self._memory:
            return False
        self._memory[nonce] = expires_at
        return True
