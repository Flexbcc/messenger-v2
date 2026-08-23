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
        try:
            conn.execute("ALTER TABLE buffered_envelopes ADD COLUMN packet_id TEXT")
        except sqlite3.OperationalError:
            pass
        # Recover packet_id for legacy rows without deleting or rewriting their
        # ciphertext. Malformed legacy envelopes remain nullable and readable.
        rows = conn.execute(
            "SELECT id, envelope_json FROM buffered_envelopes WHERE packet_id IS NULL"
        ).fetchall()
        import json
        for row in rows:
            try:
                packet_id = json.loads(row["envelope_json"]).get("packet_id")
            except (AttributeError, TypeError, ValueError):
                packet_id = None
            if isinstance(packet_id, str) and packet_id:
                conn.execute(
                    "UPDATE buffered_envelopes SET packet_id = ? WHERE id = ?",
                    (packet_id, row["id"]),
                )
        try:
            conn.execute(
                """CREATE UNIQUE INDEX IF NOT EXISTS uq_buffer_recipient_packet
                   ON buffered_envelopes(recipient_device_id, packet_id)
                   WHERE packet_id IS NOT NULL"""
            )
        except sqlite3.IntegrityError:
            # Preserve legacy duplicates rather than deleting data during a
            # migration. Application-level idempotency still protects new writes.
            conn.execute(
                """CREATE INDEX IF NOT EXISTS idx_buffer_recipient_packet
                   ON buffered_envelopes(recipient_device_id, packet_id)"""
            )
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS opaque_mailbox_cells (
                id TEXT PRIMARY KEY,
                mailbox_token TEXT NOT NULL,
                mailbox_hash TEXT,
                cell_hash TEXT NOT NULL,
                cell_b64 TEXT NOT NULL,
                cell_size INTEGER NOT NULL,
                created_at TEXT NOT NULL,
                expires_at TEXT NOT NULL,
                UNIQUE(mailbox_token, cell_hash)
            )
            """
        )
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS synthetic_challenge_cells (
                token TEXT PRIMARY KEY,
                observer_node_id TEXT NOT NULL,
                cell_hash TEXT NOT NULL,
                cell_b64 TEXT NOT NULL,
                expires_at TEXT NOT NULL
            )
            """
        )
        challenge_columns = {
            row[1] for row in conn.execute("PRAGMA table_info(synthetic_challenge_cells)")
        }
        if "observer_node_id" not in challenge_columns:
            conn.execute(
                "ALTER TABLE synthetic_challenge_cells ADD COLUMN observer_node_id TEXT NOT NULL DEFAULT 'legacy'"
            )
        columns = {
            row[1] for row in conn.execute("PRAGMA table_info(opaque_mailbox_cells)")
        }
        if "mailbox_hash" not in columns:
            conn.execute("ALTER TABLE opaque_mailbox_cells ADD COLUMN mailbox_hash TEXT")
        import hashlib
        legacy_rows = conn.execute(
            "SELECT id, mailbox_token FROM opaque_mailbox_cells WHERE mailbox_hash IS NULL"
        ).fetchall()
        for row in legacy_rows:
            conn.execute(
                "UPDATE opaque_mailbox_cells SET mailbox_hash = ? WHERE id = ?",
                (hashlib.sha256(row["mailbox_token"].encode("ascii")).hexdigest(), row["id"]),
            )
        conn.execute(
            """CREATE INDEX IF NOT EXISTS idx_opaque_mailbox_created
               ON opaque_mailbox_cells(mailbox_hash, created_at)"""
        )
        conn.execute(
            """CREATE UNIQUE INDEX IF NOT EXISTS uq_opaque_mailbox_hash_cell
               ON opaque_mailbox_cells(mailbox_hash, cell_hash)"""
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
