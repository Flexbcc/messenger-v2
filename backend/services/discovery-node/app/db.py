"""
Discovery Node storage.

Role per spec/0604_DISCOVERY_NODE.md: resolve UserID -> Home Node address
and publish node Capability. Control Plane trust lifecycle — ADR-0009.
Does not touch message content, does not participate in delivery.
"""
import sqlite3
import os
from contextlib import contextmanager

DB_PATH = os.environ.get("DISCOVERY_DB_PATH", "discovery.db")


def _add_column_if_missing(conn: sqlite3.Connection, table: str, column: str, definition: str) -> None:
    try:
        conn.execute(f"ALTER TABLE {table} ADD COLUMN {column} {definition}")
    except sqlite3.OperationalError:
        pass


def init_db():
    with get_conn() as conn:
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS user_records (
                user_id TEXT PRIMARY KEY,
                home_node_url TEXT NOT NULL,
                display_name TEXT,
                auth_public_key TEXT NOT NULL,
                cluster_id TEXT NOT NULL DEFAULT 'default',
                updated_at TEXT NOT NULL
            )
            """
        )
        _add_column_if_missing(conn, "user_records", "cluster_id", "TEXT NOT NULL DEFAULT 'default'")
        _add_column_if_missing(conn, "user_records", "login", "TEXT")
        _add_column_if_missing(conn, "user_records", "username_search_enabled", "INTEGER NOT NULL DEFAULT 1")
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_user_records_login ON user_records(login)"
        )

        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS node_capabilities (
                node_id TEXT PRIMARY KEY,
                node_url TEXT NOT NULL,
                capabilities TEXT NOT NULL,
                software_version TEXT NOT NULL DEFAULT 'unknown',
                last_heartbeat TEXT NOT NULL,
                cluster_id TEXT NOT NULL DEFAULT 'default',
                trust_status TEXT NOT NULL DEFAULT 'unknown',
                node_token_hash TEXT,
                enrollment_secret_hash TEXT,
                token_issued_at TEXT,
                token_claimed_at TEXT,
                approved_at TEXT,
                approved_by TEXT,
                suspended_at TEXT,
                suspension_reason TEXT,
                registered_at TEXT
            )
            """
        )
        _add_column_if_missing(conn, "node_capabilities", "cluster_id", "TEXT NOT NULL DEFAULT 'default'")
        for col, defn in (
            ("trust_status", "TEXT NOT NULL DEFAULT 'unknown'"),
            ("node_token_hash", "TEXT"),
            ("enrollment_secret_hash", "TEXT"),
            ("token_issued_at", "TEXT"),
            ("token_claimed_at", "TEXT"),
            ("approved_at", "TEXT"),
            ("approved_by", "TEXT"),
            ("suspended_at", "TEXT"),
            ("suspension_reason", "TEXT"),
            ("registered_at", "TEXT"),
            ("build_hash", "TEXT"),
            ("tls_cert_fingerprint", "TEXT"),
            ("release_signature", "TEXT"),
            ("attestation_status", "TEXT NOT NULL DEFAULT 'skipped'"),
            ("attestation_detail", "TEXT"),
            ("signing_public_key", "TEXT"),
            # Active health-check (Node Monitor)
            ("health_status", "TEXT"),
            ("last_health_check", "TEXT"),
            # Vulnerability response / version quarantine
            ("version_status", "TEXT NOT NULL DEFAULT 'ok'"),
            ("quarantine_action", "TEXT NOT NULL DEFAULT 'off'"),
        ):
            _add_column_if_missing(conn, "node_capabilities", col, defn)

        # Vulnerability response: blocked (vulnerable) software versions.
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS blocked_versions (
                version TEXT PRIMARY KEY,
                reason TEXT,
                blocked_at TEXT NOT NULL
            )
            """
        )
        # Network-level policy KV (quarantine_mode, force_upgrade, ...).
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS discovery_settings (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            )
            """
        )

        # Grandfather existing rows from pre-enrollment schema.
        conn.execute(
            """
            UPDATE node_capabilities
            SET trust_status = 'trusted',
                registered_at = COALESCE(registered_at, last_heartbeat)
            WHERE trust_status = 'unknown' OR trust_status IS NULL OR trust_status = ''
            """
        )
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_node_trust_status ON node_capabilities(trust_status)"
        )
        # Seed policy defaults from env (idempotent — INSERT OR IGNORE).
        from app.policy import _seed_settings
        _seed_settings(conn)
        conn.commit()


@contextmanager
def get_conn():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    try:
        yield conn
    finally:
        conn.close()
