"""
Storage Node: temporary buffer for offline recipients.
Role per spec/0602_STORAGE_NODE.md — holds only ciphertext, no decryption
capability, deleted after delivery or TTL expiry.
"""
import sqlite3
import os
from contextlib import contextmanager

DB_PATH = os.environ.get("STORAGE_DB_PATH", "storage.db")


def init_db():
    with get_conn() as conn:
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS buffered_envelopes (
                id TEXT PRIMARY KEY,
                recipient_device_id TEXT NOT NULL,
                envelope_json TEXT NOT NULL,
                created_at TEXT NOT NULL,
                expires_at TEXT NOT NULL
            )
            """
        )
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_recipient ON buffered_envelopes(recipient_device_id)"
        )
        conn.commit()


@contextmanager
def get_conn():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    try:
        yield conn
    finally:
        conn.close()
