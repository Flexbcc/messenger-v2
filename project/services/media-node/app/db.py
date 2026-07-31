import json
import os
import sqlite3
from contextlib import contextmanager
from pathlib import Path

DB_PATH = os.environ.get("MEDIA_DB_PATH", "media.db")


def init_db():
    with get_conn() as conn:
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS media_objects (
                media_id TEXT PRIMARY KEY,
                owner_user_id TEXT,
                tier TEXT NOT NULL DEFAULT 'primary',
                backend TEXT NOT NULL,
                object_key TEXT NOT NULL,
                size_bytes INTEGER NOT NULL,
                created_at TEXT NOT NULL,
                expires_at TEXT,
                last_access_at TEXT
            )
            """
        )
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_media_expires ON media_objects(expires_at)"
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
